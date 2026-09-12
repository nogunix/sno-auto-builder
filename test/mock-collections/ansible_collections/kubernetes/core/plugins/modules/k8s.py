#!/usr/bin/python
"""Test double for kubernetes.core.k8s.

Shadows the real module on ANSIBLE_COLLECTIONS_PATH so 04-deploy-mcp-server.yml
can create its ServiceAccount, bindings and token Secret without a cluster.
Accepts any definition and reports it as created.
"""
from ansible.module_utils.basic import AnsibleModule


def main():
    module = AnsibleModule(
    argument_spec=dict(
        kubeconfig=dict(type="str"),
        state=dict(type="str", default="present"),
        definition=dict(type="dict"),
    ),
        supports_check_mode=True,
    )
    definition = module.params.get("definition") or {}
    module.exit_json(changed=True, method="create", result=definition)


if __name__ == "__main__":
    main()
