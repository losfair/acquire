"use client";

import { companyColorClasses } from "@/utils/colors";
import { apiFetch } from "@/utils/http";
import { Roomctl } from "@/utils/roomctl";
import { useRouter } from "next/navigation";
import { useRef, useState } from "react";

export default function Waitroom({ ctl }: { ctl: Roomctl }) {
    const router = useRouter();
    const [player, setPlayer] = useState("")

    if (!ctl.player) {
        return (
            <div className="flex flex-col border border-black p-4 gap-4">
                <div>
                    <span className="font-bold text-xl text-black">加入游戏</span>
                </div>
                <input className="border border-black bg-gray-200" onChange={(e) => setPlayer(e.target.value)} placeholder="昵称" />
                <div>
                    <button className="bg-black text-white rounded-lg px-8 py-3" onClick={() => {
                        apiFetch(`/rooms/${ctl.id}/join`, {
                            method: "POST",
                            body: JSON.stringify({ player })
                        }).then(() => {
                            router.push(`/game/?id=${ctl.id}&player=${encodeURIComponent(player)}`)
                        }).catch(e => {
                            alert(`start_game: ${e}`)
                        })
                    }}>OK</button>
                </div>
            </div>
        )
    }

    return (
        <div className="flex flex-col gap-4 pb-4">
            <div>
                <span className="font-bold text-xl text-black">等待所有玩家加入...</span>
            </div>
            <div>
                <button className="bg-black text-white text-sm rounded-lg px-6 py-2" onClick={() => {
                    apiFetch(`/rooms/${ctl.id}/start_game`, {
                        method: "POST",
                        body: JSON.stringify({})
                    }).catch(e => {
                        alert(`start_game: ${e}`)
                    })
                }}>开始游戏</button>
            </div>
        </div>
    )
}