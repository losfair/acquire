"use client";

import { companyColorClasses } from "@/utils/colors";
import { Player, RoomSummary } from "@/utils/types";
import { useMemo, useRef, useState } from "react";

export default function PlayerInfo({ summary, me }: { summary: RoomSummary, me: string }) {
    const rotatedPlayers = useMemo(() => rotatePlayers(summary.players, me), [summary.players, me])

    return (
        <div className="flex flex-col">
            {!!rotatedPlayers.length && <div className="font-bold">玩家</div>}

            {rotatedPlayers.map((player, i) => <SinglePlayer key={player.id} player={player} summary={summary} isMe={i === 0} />)}
        </div>
    )
}

function SinglePlayer({ player, summary, isMe }: { player: Player, summary: RoomSummary, isMe: boolean }) {
    const currentPlayerId = summary.status === "finished" ? "" :
        summary.status === "distributing" ? summary.distributing[0] :
            summary.players[0]?.id;
    const isCurrent = player.id === currentPlayerId;

    return (
        <div className={`flex flex-col p-2 text-black border-b border-gray-700`}>
            <div className="flex flex-row gap-0 pb-1">
                <div className={`font-bold text-md`}>
                    <span>{player.id}</span>
                    {isMe && <span className="text-blue-500 pl-2">{
                        "[你]"
                    }</span>}
                    {isCurrent && <span className="text-red-500 pl-2">{
                        "[当前]"
                    }</span>}
                </div>
                <div className="grow"></div>
                <span className={`text-md font-mono`}>{`$${player.balance}`}</span>
            </div>
            <div className="flex flex-row gap-2">
                {Object.entries(player.stocks).map(([companyId, n]) => {
                    const company = summary.companies[companyId];
                    const [bg, fg] = companyColorClasses(companyId, company.color || "");
                    return (
                        <div key={companyId} className={`w-8 h-8 leading-8 text-center rounded-lg ${bg}`}>
                            <span className={`${fg}`}>{n}</span>
                        </div>
                    )
                })}
            </div>
        </div>
    )
}

function rotatePlayers(input: Player[], me: string): Player[] {
    const myIndex = input.findIndex(x => x.id === me);
    if (myIndex < 0) return input;

    return [...input.slice(myIndex), ...input.slice(0, myIndex)]
}