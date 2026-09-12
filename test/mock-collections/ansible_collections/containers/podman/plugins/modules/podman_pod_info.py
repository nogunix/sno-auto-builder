#!/usr/bin/python
"""Test double for containers.podman.podman_pod_info.

Returns no pods by default, which is what drives 04's `mcp_needs_deploy` guard
down its deploy branch. Set MOCK_POD_RUNNING=1 to return a Running pod instead
and exercise the "already up, do not bounce it" branch.
"""
import os

from ansible.module_utils.basic import AnsibleModule


def main():
    module = AnsibleModule(
    argument_spec=dict(
        name=dict(type="str"),
    ),
        supports_check_mode=True,
    )
    if os.environ.get("MOCK_POD_RUNNING") == "1":
        pods = [{"Name": module.params.get("name"), "State": "Running"}]
    else:
        pods = []
    module.exit_json(changed=False, pods=pods)


if __name__ == "__main__":
    main()
