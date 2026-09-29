#!/usr/bin/env python3
"""Summarize observed callbacks, without declaring screen-lock/suspension proof."""
import argparse
from collections import Counter
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    events = []
    for number, line in enumerate(args.log.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
            if not isinstance(event, dict) or not all(k in event for k in ("event", "runID", "appState", "timestamp")):
                raise ValueError("missing probe fields")
            events.append(event)
        except (ValueError, TypeError) as error:
            parser.error(f"Invalid line {number}: {error}; evidence is incomplete")

    print(f"Events: {len(events)}; processes: {len({e['runID'] for e in events})}")
    for name, count in sorted(Counter(e["event"] for e in events).items()):
        print(f"  {name}: {count}")
    print("\nConnection callbacks (background duration is wall-clock evidence only):")
    for event in events:
        if event["event"] == "connected":
            print(f"  {event['timestamp']} state={event['appState']} "
                  f"backgroundSeconds={event.get('backgroundSeconds', 'unknown')} "
                  f"protectedData={event.get('protectedDataAvailable', 'unknown')} "
                  f"trial={event.get('trialID', 'none')} run={event['runID']}")
    print("\nRestoration callbacks:")
    for event in events:
        if event["event"] == "central_restored":
            print(f"  {event['timestamp']} run={event['runID']} {event.get('details', {})}")
    if any(e["event"] == "identifier_cache_miss_filtered_scan" for e in events):
        print("\nNOTICE: Filtered recovery scan occurred; check the trial before attributing a connection to pending connect.")
    if any(e["event"] == "reconnect_circuit_open" for e in events):
        print("\nNOTICE: Automatic waiting paused after rapid terminal callbacks.")
    print("\nCompare these events with the physical lock and step-on times you recorded. "
          "Counts do not prove a reliable wake, authenticated measurement, or HealthKit write.")


if __name__ == "__main__":
    main()
