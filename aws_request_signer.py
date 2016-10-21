from boto.connection import AWSAuthConnection
import os
import sys

class AWSConnection(AWSAuthConnection):

    def __init__(self, region, service, **kwargs):
        super(AWSConnection, self).__init__(**kwargs)
        self._set_auth_region_name(region)
        self._set_auth_service_name(service)

    def _required_auth_capability(self):
        return ['hmac-v4']

if __name__ == "__main__":

    service = sys.argv[1]
    region = sys.argv[2]
    host = sys.argv[3]
    http_method = sys.argv[4]
    path = sys.argv[5]
    data = sys.argv[6]

    client = AWSConnection(region=region, service=service, host=host, is_secure=False)
    resp = client.make_request(method=http_method, path=path, data=data)
    body = resp.read()
    print body