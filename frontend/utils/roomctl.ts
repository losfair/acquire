import { useEffect, useState } from "react";
import { apiUrl } from "./http";
import { RoomSummary } from "./types";

export interface RoomctlEventMap {
    'room-updated': RoomUpdatedEvent;
}

export interface RoomctlEventTarget extends EventTarget {
    addEventListener<K extends keyof RoomctlEventMap>(
        type: K,
        listener: (ev: RoomctlEventMap[K]) => void,
        options?: boolean | AddEventListenerOptions
    ): void;
    addEventListener(
        type: string,
        callback: EventListenerOrEventListenerObject | null,
        options?: EventListenerOptions | boolean
    ): void;

    removeEventListener<K extends keyof RoomctlEventMap>(
        type: K,
        listener: (ev: RoomctlEventMap[K]) => void,
        options?: boolean | EventListenerOptions
    ): void;

    removeEventListener(
        type: string,
        callback: EventListenerOrEventListenerObject | null,
        options?: EventListenerOptions | boolean
    ): void;
}

const roomctlEventTarget = EventTarget as { new(): RoomctlEventTarget; prototype: RoomctlEventTarget };

export class Roomctl extends roomctlEventTarget {
    private events: EventSource
    private summary: RoomSummary | null = null;

    constructor(public readonly id: string, public readonly player: string) {
        super()
        this.events = new EventSource(apiUrl(`/rooms/${encodeURIComponent(id)}/events`));
        this.events.addEventListener("message", (event) => {
            const summary: RoomSummary = JSON.parse(event.data)
            this.summary = summary;
            this.dispatchEvent(new RoomUpdatedEvent(summary))
        })
    }

    public getSummary(): RoomSummary {
        if (!this.summary) throw new Error("Summary is not available")
        return this.summary
    }

    public useSummary(): RoomSummary {
        const [get, set] = useState(() => this.getSummary());
        useEffect(() => {
            const cb = (x: RoomUpdatedEvent) => {
                set(x.summary);
            }
            this.addEventListener("room-updated", cb)
            return () => this.removeEventListener("room-updated", cb)
        })

        return get;
    }

    close() {
        this.events.close()
    }
}

export class RoomUpdatedEvent extends Event {
    constructor(public readonly summary: RoomSummary) {
        super("room-updated")
    }
}