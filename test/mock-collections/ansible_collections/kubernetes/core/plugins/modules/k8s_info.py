#!/usr/bin/python
"""Test double for kubernetes.core.k8s_info.

04-deploy-mcp-server.yml only reads one thing through this module: the
ServiceAccount token Secret. Return a populated, base64-encoded token so the
`until: ... data.token is defined` retry loop succeeds on the first pass.
"""
import base64
import os

from ansible.module_utils.basic import AnsibleModule


def main():
    module = AnsibleModule(
    argument_spec=dict(
        kubeconfig=dict(type="str"),
        api_version=dict(type="str"),
        kind=dict(type="str"),
        name=dict(type="str"),
        namespace=dict(type="str"),
    ),
        supports_check_mode=True,
    )
    token = os.environ.get("MOCK_SA_TOKEN", "mock-serviceaccount-token")
    module.exit_json(changed=False, resources=[{
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": module.params.get("name")},
        "type": "kubernetes.io/service-account-token",
        "data": {"token": base64.b64encode(token.encode()).decode()},
    }])


if __name__ == "__main__":
    main()
