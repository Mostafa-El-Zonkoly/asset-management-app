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
        self.events.put((self.item, values))

    def onSubscriptionError(self, code, _message):
        self.events.put((self.item, {"error": f"Lightstreamer subscription error {code}"}))


class ConnectionListener(ClientListener):
    def __init__(self, events):
        self.events = events

    def onStatusChange(self, status):
        self.events.put(("status", status))

    def onServerError(self, code, _message):
        self.events.put(("connection", {"error": f"Lightstreamer server error {code}"}))


def fetch(request, report):
    events = Queue()
    required_fields = {"mk1": ["m_MarketStatus", "MarketTime"]}
    for index_id in request["index_ids"]:
        required_fields[f"ix{index_id}"] = ["m_IndexID", "m_IndexValue"]

    client = LightstreamerClient("https://iengine138.hermesonline.com/", ADAPTER)
    client.connectionDetails.setUser(request["trading_id"])
    client.connectionDetails.setPassword(request["token"])
    client.addListener(ConnectionListener(events))

    pending = set(required_fields)
    results = {}
    observed = {}
    connection_status = "not started"
    try:
        for item, required in required_fields.items():
            fields = required if item == "mk1" else [*required, "m_EnglishName"]
            subscription = Subscription("MERGE", [item], fields)
            subscription.setDataAdapter(ADAPTER)
            subscription.setRequestedSnapshot("yes")
            subscription.addListener(SnapshotListener(events, item, fields))
            client.subscribe(subscription)

        report("connecting")
        client.connect()
        deadline = monotonic() + 20
        while pending and monotonic() < deadline:
            try:
                item, values = events.get(timeout=max(0, deadline - monotonic()))
            except Empty:
                break
            if item == "connection":
                return {**results, "error": values["error"], "connection_status": connection_status}
            if item == "status":
                connection_status = values
                report("connection_status", status=connection_status)
            elif item in pending:
                observed[item] = values
                if "error" in values or all(values.get(field) not in (None, "") for field in required_fields[item]):
                    results[item] = values
                    pending.remove(item)
                    report("subscription_answered", item=item, error=values.get("error"))

        for item in sorted(pending):
            if item in observed:
                values = observed[item]
                missing = [field for field in required_fields[item] if values.get(field) in (None, "")]
                results[item] = {"error": f"EFG snapshot {item} is missing {', '.join(missing)}"}
            else:
                results[item] = {"error": f"No EFG snapshot received for {item}"}
        return {**results, "connection_status": connection_status}
    finally:
        report("disconnecting")
        client.disconnect()


def report_progress(event, **fields):
    print(json.dumps({"event": event, **fields}), flush=True)


if __name__ == "__main__":
    try:
        result = fetch(json.load(sys.stdin), report_progress)
    except Exception as error:
        # Exception messages can include connection details.
        result = {"error": f"EFG stream helper raised {type(error).__name__}"}
    print(json.dumps(result), flush=True)
