# Issues

These are the integration-test issues that still reproduce on
`www-dstest4.staging.newsnow.co.uk` as of 2026-04-06.

1. Editing developers/viewers triggers a backend Docker network error (`05_edit`)
   Tests affected:
   - `05_edit.EditTests.test_03_edit_developers`
   - `05_edit.EditTests.test_04_edit_combined`
   - `05_edit.EditTests.test_05_viewer_cannot_edit`
   - `05_edit.EditTests.test_06_non_owner_developer_can_edit_allowed_fields`
   - `05_edit.EditTests.test_07_dev2_cannot_edit_when_not_developer`

   Current failure:
   - `Internal error - Error running '/usr/bin/docker network connect ds-priv <container-id>': message '', exit code 1`

   Notes:
   - This is no longer a client-side or CLI validation problem.
   - The failure is triggered by the server-side reservation/container update path
     when editing developers (and combined edits that include developers).
   - The likely issue is that the backend attempts to re-run
     `docker network connect ds-priv ...` for a container that is already attached,
     and treats Docker's non-zero exit as fatal.

2. Newly created containers still report no network (`08_network`)
   Test affected:
   - `08_network.NetworkTests.test_01_create_default_network`

   Current failure:
   - `container has no network after creation`

   Notes:
   - The test checks the network value returned by Dockside (`data.network` or
     `network`) after a normal create/get cycle.
   - It is not yet clear whether the network is actually absent on the Docker
     side or only missing from the API response/derived reservation data.

3. Expected environment-driven skips in `08_network`
   These are not failures, but they still explain why `08` does not exercise the
   full network matrix in `remote` mode:

   - `test_02_create_on_discovered_network`
     - skipped when no alternate available network can be discovered from
       existing containers
   - `test_04_edit_network`
     - skipped when only one available network is visible
   - `test_05_create_and_attach_test_network`
   - `test_06_test_network_disappears_after_detach`
     - skipped in `remote` mode unless `DOCKSIDE_TEST_ALLOW_NETWORK_MODIFY=1`
