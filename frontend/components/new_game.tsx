"use client";

import { apiFetch } from "@/utils/http"
import standardGame from "../../games/standard.json" with {type: "json"}
import fastGame from "../../games/fast.json" with {type: "json"}
import { useRouter } from "next/navigation";
import type { AppRouterInstance } from "next/dist/shared/lib/app-router-context.shared-runtime";
import { useRef } from "react";

async function start(router: AppRouterInstance, config: string) {
    const now = Date.now();
    const nonce = Math.random()
    const { room_id }: { room_id: string } = await (await apiFetch(
        `/rooms?timestamp=${now}&nonce=${nonce}`,
        { method: "POST", body: config }
    )).json()
    router.push(`/game/?id=${room_id}`);
}

export default function NewGame() {
    const router = useRouter();
    const configUploader = useRef(null as HTMLInputElement | null)

    return (
        <div className="absolute top-0 left-0 w-full h-full">
            <div className="mx-auto mt-40 max-w-lg flex flex-col gap-8 items-center select-none">
                <h1 style={{ fontSize: "60px" }} className="font-bold">Acquire</h1>
                <div
                    className="bg-black text-white w-80 items-left px-4 py-8 flex flex-col gap-4 text-sm cursor-pointer"
                    onClick={() => {
                        start(router, JSON.stringify(standardGame))
                    }}
                >
                    <span className="font-bold text-xl">标准模式</span>
                    <span>9行12列/7家公司/2-6人</span>
                </div>
                <div
                    className="bg-black text-white w-80 items-left px-4 py-8 flex flex-col gap-4 text-sm cursor-pointer"
                    onClick={() => {
                        start(router, JSON.stringify(fastGame))
                    }}
                >
                    <span className="font-bold text-xl">快速模式</span>
                    <span>5行8列/4家公司/2-6人</span>
                </div>
                <div className="border border-black bg-white text-black w-80 items-left px-4 py-8 flex flex-col gap-4 text-sm cursor-pointer" onClick={() => {
                    const field = configUploader.current
                    if (!field) return;
                    field.value = "";

                    let listener = function (ev: Event) {
                        field.removeEventListener("change", listener)
                        ev.preventDefault()

                        const file = field.files?.[0]
                        if (!file) return;

                        (async () => {
                            const text = await file.text()
                            await start(router, text)
                        })().catch(e => {
                            alert(`starting game: ${e}`)
                        })
                    }
                    field.addEventListener("change", listener)
                    field.click();
                }}>
                    <span className="font-bold text-xl">自定义</span>
                    <span>上传配置</span>
                    <input
                        type="file"
                        ref={configUploader}
                        style={{ display: "none" }} onClick={(e) => {
                            e.stopPropagation();
                        }} />
                </div>
            </div>
        </div>
    )
}
