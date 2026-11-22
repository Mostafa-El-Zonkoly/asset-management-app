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
# Match the Younit SDK's IndexStatistics subscription schema and field order.
INDEX_FIELDS = [
    "key",
    "m_IndexID",
    "m_IndexName",
    "m_EnglishName",
    "m_IndexType",
    "m_MarketName",
    "m_MarketID",
    "m_IndexValue",
    "m_IndexOpen",
    "m_IndexClose",
    "m_IndexHigh",
    "m_IndexLow",
    "m_IndexWk52High",
    "m_IndexWk52Low",
    "m_NetChange",
    "m_PrecentChange",
    "m_ChangeDir",
    "m_TradedValue",
    "m_TradedVolume",
]


class SnapshotListener(SubscriptionListener):
    def __init__(self, events, item, fields):
        self.events = events
        self.item = item
        self.fields = fields

    def onSubscription(self):
        self.events.put(("subscribed", self.item))

    def onEndOfSnapshot(self, _item_name, _item_pos):
        self.events.put(("snapshot_ended", self.item))

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
    confirmed = set()
    connection_status = "not started"
    try:
        for item, required in required_fields.items():
            fields = required if item == "mk1" else INDEX_FIELDS
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
            elif item == "subscribed":
                confirmed.add(values)
                report("subscription_accepted", item=values)
            elif item == "snapshot_ended":
                report("snapshot_ended", item=values, received_update=values in observed)
            elif item in pending:
                if item not in observed and "error" not in values:
                    available = [field for field, value in values.items() if value not in (None, "")]
                    report("first_update", item=item, available_fields=available)
                observed[item] = values
                if "error" in values or all(values.get(field) not in (None, "") for field in required_fields[item]):
                    results[item] = values
                    pending.remove(item)
                    report("subscription_answered", item=item, error=values.get("error"))

        for item in sorted(pending):
            if item in observed:
                values = observed[item]
                missing = [field for field in required_fields[item] if values.get(field) in (None, "")]
                if any(value not in (None, "") for value in values.values()):
                    reason = f"EFG snapshot {item} is missing {', '.join(missing)}"
                else:
                    reason = f"EFG sent an empty snapshot for {item}"
                results[item] = {"error": reason}
            elif item in confirmed:
                results[item] = {"error": f"EFG accepted {item} but sent no snapshot within 20 seconds"}
            else:
                results[item] = {"error": f"EFG did not confirm or send a snapshot for {item} within 20 seconds"}
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
