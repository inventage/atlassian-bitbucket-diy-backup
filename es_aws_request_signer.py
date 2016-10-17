from boto.connection import AWSAuthConnection
import os

class ESConnection(AWSAuthConnection):

    def __init__(self, region, **kwargs):
        super(ESConnection, self).__init__(**kwargs)
        self._set_auth_region_name(region)
        self._set_auth_service_name("es")

    def _required_auth_capability(self):
        return ['hmac-v4']

if __name__ == "__main__":
    client = ESConnection(
            region=os.environ['ES_AWS_REGION'],
            host=os.environ['ES_HOST'],
            is_secure=False)

    resp = client.make_request(method=os.environ['ES_HTTP_METHOD'], path=os.environ['ES_PATH'], data=os.environ['ES_DATA'])
    body = resp.read()
    print body