# Advanced Launch Options

## Launch with self-signed SSL certificate

For use on a local machine, on-premises server, VM or cloud instance where you want to use your own domain name but do not yet have a public SSL certificate, launch Dockside with a self-signed certificate. Replace `<my-domain>` with your chosen domain name:

```sh
mkdir -p ~/.dockside && \
docker run -it --name dockside \
  -v ~/.dockside:/data \
  --mount=type=volume,src=dockside-ssh-hostkeys,dst=/opt/dockside/host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 443:443 -p 80:80 \
  --security-opt=apparmor=unconfined \
  newsnowlabs/dockside --ssl-selfsigned --ssl-zone <my-domain>
```

Navigate to `https://www.<my-domain>/` (configure your DNS or `/etc/hosts` file as needed). Sign in with the username `admin` and the auto-generated password output to the terminal, then follow the instructions displayed on-screen.

You can [detach](https://docs.docker.com/engine/reference/commandline/attach/) from the container by typing `CTRL+P` `CTRL+Q`, or launch with `docker run -d` and retrieve the password with `docker logs dockside`.

## Launch with self-supplied SSL certificate

If you already hold a wildcard SSL certificate for `<my-domain>`, place `fullchain.pem` and `privkey.pem` in `<certsdir>` and launch as follows:

```sh
mkdir -p ~/.dockside && \
docker run -d --name dockside \
  -v ~/.dockside:/data \
  --mount=type=volume,src=dockside-ssh-hostkeys,dst=/opt/dockside/host \
  -v <certsdir>:/data/certs \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 443:443 -p 80:80 \
  --security-opt=apparmor=unconfined \
  newsnowlabs/dockside --ssl-selfsupplied
```

Navigate to `https://www.<my-domain>/`. Run `docker logs dockside` to obtain the auto-generated `admin` password.

> **Note:** To reload updated certificates run `docker exec dockside s6-svc -t /etc/service/nginx`.

## Google Cloud Deployment Manager _(deprecated)_

> An implementation of the LetsEncrypt launch procedure within [Google Deployment Manager](https://console.cloud.google.com/dm/deployments) is available [here](https://github.com/newsnowlabs/dockside/tree/main/examples/cloud/google-deployment-manager). To use it, you must first configure a managed zone within [Google Cloud DNS](https://console.cloud.google.com/net-services/dns/zones).
>
> Sign into Cloud Shell, and run:
> ```sh
> git clone https://github.com/newsnowlabs/dockside.git
> cd dockside/examples/cloud/google-deployment-manager/
> ./launch.sh --managed-zone <managed-zone> --dns-name <managed-zone-fully-qualified-subdomain>
> ```
> For example, if your managed zone is called `myzone`, the zone DNS name is `myzone.org`, and your chosen subdomain is `dockside`, run `./launch.sh --managed-zone myzone --dns-name dockside.myzone.org`.
>
> For full `launch.sh` usage, including options for configuring cloud machine type, machine zone, and disk size, run `./launch.sh --help`.

## Terraform

> _Terraform launch instructions coming soon._
