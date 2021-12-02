#!/bin/bash

CLOUD_MACHINE_ZONE="us-central1-a"
CLOUD_MACHINE_TYPE="n1-standard-4"
CLOUD_DISK_SIZE="100" # GB
CLOUD_DISK_IMAGE="projects/debian-cloud/global/images/debian-10-buster-v20210916"
DOCKSIDE_IMAGE="newsnowlabs/dockside:latest"
SSH_KEY="$HOME/.ssh/google_compute_engine"
OPTIONS=()

error() {
  cat >&2 <<_EOE_
$0: $1

_EOE_

  usage
}

usage() {
  cat >&2 <<_EOE_
  Usage: $0 [OPTIONS...]

  MINIMUM OPTIONS

  --managed-zone <cloud-dns-managed-zone>    - Cloud DNS managed zone name to update
  --dns-name <fully-qualified-subdomain>     - Fully-qualified subdomain of zone to update

  ADDITIONAL OPTIONS

  --machine-zone <compute-machine-zone>      - Default $CLOUD_MACHINE_ZONE
  --machine-type <compute-machine-type>      - Default $CLOUD_MACHINE_TYPE
  --disk-size <size-in-gb>                   - Default $CLOUD_DISK_SIZE
  --disk-image <compute-image>               - Default $CLOUD_DISK_IMAGE
  --dockside-image <docker-image>            - Default $DOCKSIDE_IMAGE
  --preview                                  - Preview only, don't launch yet
  --help | -h                                - Display usage

  EXAMPLES

  $0 --managed-zone my-dockside-zone --dns-name ds.dockside.cloud

_EOE_

  exit 1
}

while [ -n "$1" ]
do
  case "$1" in
      --managed-zone) shift; CLOUD_DNS_ZONE="$1"; shift; continue; ;;
          --dns-name) shift; DNS_NAME="$1"; shift; continue; ;;

      --machine-zone) shift; CLOUD_MACHINE_ZONE="$1"; shift; continue; ;;
      --machine-type) shift; CLOUD_MACHINE_TYPE="$1"; shift; continue; ;;
         --disk-size) shift; CLOUD_DISK_SIZE="$1"; shift; continue; ;;
        --disk-image) shift; CLOUD_DISK_IMAGE="$1"; shift; continue; ;;
    --dockside-image) shift; DOCKSIDE_IMAGE="$1"; shift; continue; ;;

           --preview) shift; OPTIONS+=("--preview"); continue; ;;

           -h|--help) shift; usage; ;;
                   *) error "Unknown option '$1'"; ;;
  esac
done

if [ -z "$CLOUD_DNS_ZONE" ] || [ -z "$DNS_NAME" ]; then
  usage
fi

DNS_PREFIX=$(echo $DNS_NAME | cut -d'.' -f1)
NAME=$(echo $DNS_NAME | tr '.' '-')

echo "Launching Dockside ..." >&2
gcloud -q --verbosity=error deployment-manager deployments create dockside-$NAME \
  --template dockside.jinja \
  "${OPTIONS[@]}" \
  --properties=name:$NAME,managed_zone:$CLOUD_DNS_ZONE,dns_name:$DNS_NAME,machine_zone:$CLOUD_MACHINE_ZONE,machine_type:$CLOUD_MACHINE_TYPE,disk_size:$CLOUD_DISK_SIZE,disk_image:$CLOUD_DISK_IMAGE,dockside_image:$DOCKSIDE_IMAGE \
  || exit 2

# Now run 'gcloud beta dns' to add the following resourceRecordSets record, which is not yet supported by deployment manager:
#
#   - type: NS
#     ttl: 30
#     rrdatas:
#     - {{ properties["prefix"] }}.{{ properties["dns_zone"] }}
#
echo >&2
echo "Setting NS record for $DNS_NAME in managed zone $CLOUD_DNS_ZONE ..." >&2
gcloud -q  --verbosity=error beta dns record-sets transaction abort --zone="$CLOUD_DNS_ZONE" 2>/dev/null
gcloud -q  --verbosity=error beta dns record-sets transaction start --zone="$CLOUD_DNS_ZONE" 2>/dev/null
gcloud -q  --verbosity=error beta dns record-sets transaction remove "${DNS_NAME}." --name="${DNS_NAME}." --ttl="300" --type="NS" --zone="$CLOUD_DNS_ZONE" 2>/dev/null
gcloud -q  --verbosity=error beta dns record-sets transaction add "${DNS_NAME}." --name="${DNS_NAME}." --ttl="300" --type="NS" --zone="$CLOUD_DNS_ZONE" 2>/dev/null
gcloud -q  --verbosity=error beta dns record-sets transaction execute --zone="$CLOUD_DNS_ZONE"

echo >&2
echo "Checking for ssh key $SSH_KEY ..." >&2
if [ -f "$SSH_KEY" ]; then

echo "Setting up ssh-agent and adding your $SSH_KEY key ..." >&2
eval $(ssh-agent)
ssh-add $SSH_KEY

echo >&2
echo "Monitoring for Dockside deployment. This may take a few minutes ..." >&2

while ! ssh -q -o UserKnownHostsFile=/tmp/.known_hosts.$$ -o StrictHostKeyChecking=no -o ConnectTimeout=2 $DNS_NAME 'sudo docker logs dockside 2>&1 | grep admin.*password'
do
  echo "Waiting 5s ..." 1>&2
  sleep 5
done

cat >&2 <<_EOE_

Now navigate to https://www.$DNS_NAME/ and sign into Dockside using the credentials printed above!
_EOE_

else

cat >&2 <<_EOE_

1. Please allow a few minutes for Dockside on $DNS_NAME to launch.
2. To obtain the admin credentials, ssh into $DNS_NAME and run:
$ sudo docker logs dockside 2>&1 | grep admin.*password
3. Finally, navigate to https://www.$DNS_NAME/ and sign into Dockside!
_EOE_

fi

exit 0