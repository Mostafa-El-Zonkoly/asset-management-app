"""Read one market snapshot and the requested index snapshots from Hermes."""
import json
import sys
from queue import Empty, Queue
from time import monotonic

try:
    from lightstreamer.client import ClientListener, LightstreamerClient, Subscription, SubscriptionListener
except ImportError:
    print(json.dumps({"error": "Lightstreamer Python client is unavailable"}))
    sys.exit(0)

ADAPTER = "PROXY_MarketBeat"


class SnapshotListener(SubscriptionListener):
    def __init__(self, events, item, fields):
        self.events = events
        self.item = item
        self.fields = fields

    def onItemUpdate(self, update):
        values = {field: update.getValue(field) for field in self.fields}
        if all(value not in (None, "") for value in values.values()):
            self.events.put((self.item, values))

    def onSubscriptionError(self, code, _message):
        self.events.put((self.item, {"error": f"Lightstreamer subscription error {code}"}))


class ConnectionListener(ClientListener):
    def __init__(self, events):
        self.events = events

    def onServerError(self, code, _message):
        self.events.put(("connection", {"error": f"Lightstreamer server error {code}"}))


def fetch(request):
    events = Queue()
    fields_by_item = {"mk1": ["m_MarketStatus", "MarketTime"]}
    for index_id in request["index_ids"]:
        fields_by_item[f"ix{index_id}"] = ["m_IndexID", "m_EnglishName", "m_IndexValue"]

    client = LightstreamerClient("https://iengine138.hermesonline.com/", ADAPTER)
    client.connectionDetails.setUser(request["trading_id"])
    client.connectionDetails.setPassword(request["token"])
    client.addListener(ConnectionListener(events))

    pending = set(fields_by_item)
    results = {}
    try:
        for item, fields in fields_by_item.items():
            subscription = Subscription("MERGE", [item], fields)
            subscription.setDataAdapter(ADAPTER)
            subscription.setRequestedSnapshot("yes")
            subscription.addListener(SnapshotListener(events, item, fields))
            client.subscribe(subscription)

        client.connect()
        deadline = monotonic() + 20
        while pending and monotonic() < deadline:
            try:
                item, values = events.get(timeout=max(0, deadline - monotonic()))
            except Empty:
                break
            if item == "connection":
                return {"error": values["error"]}
            if item in pending:
                results[item] = values
                pending.remove(item)
        for item in pending:
            results[item] = {"error": "Timed out waiting for a complete EFG snapshot"}
        return results
    finally:
        client.disconnect()


if __name__ == "__main__":
    print(json.dumps(fetch(json.load(sys.stdin))))
