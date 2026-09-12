#!/usr/bin/python
"""Test double for containers.podman.podman_secret.

04 and 99 only ever use this to remove an object; report it as absent.
"""
from ansible.module_utils.basic import AnsibleModule


def main():
    module = AnsibleModule(
    argument_spec=dict(
        name=dict(type="str", required=True),
        state=dict(type="str", default="present"),
    ),
        supports_check_mode=True,
    )
    module.exit_json(changed=True, podman_actions=["podman_secret mock"])


if __name__ == "__main__":
    main()
