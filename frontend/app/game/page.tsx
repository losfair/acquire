"use client";

import Board from "@/components/board";
import NewGame from "@/components/new_game";
import { apiUrl } from "@/utils/http";
import { Roomctl } from "@/utils/roomctl";
import { RoomSummary } from "@/utils/types";
import { useSearchParams } from "next/navigation"
import { Suspense, useEffect, useState } from "react";

export default function GamePage() {
    const params = useSearchParams();
    const [ctl, setCtl] = useState(null as Roomctl | null)
    const [room, setRoom] = useState(null as RoomSummary | null)

    useEffect(() => {
        const id = params.get("id")
        if (!id) return;

        const player = params.get("player") || ""

        let ctl = new Roomctl(id, player)
        ctl.addEventListener("room-updated", x => {
            setRoom(x.summary)
        })
        setCtl(ctl)
        return () => {
            ctl.close()
        }
    }, [setRoom, params])

    useEffect(() => {
        console.log("summary", room)
    }, [room])

    if (!params.get("id")) {
        return (
            <NewGame />
        )
    }

    if (!room || !ctl) {
        return (
            <div>
                <p>Loading</p>
            </div>
        )
    }

    return (
        <div>
            <Board ctl={ctl} />
        </div>
    )
}
