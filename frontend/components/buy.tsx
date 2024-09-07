import { companyColorClasses } from "@/utils/colors";
import { apiFetch } from "@/utils/http";
import { Roomctl } from "@/utils/roomctl";
import { useEffect, useMemo, useRef, useState } from "react";

export default function Buy({ ctl }: { ctl: Roomctl }) {
    const summary = ctl.useSummary();
    const parent = useRef(null as HTMLDivElement | null)
    const buyableCompanies = useMemo(() => {
        return new Set(Object.values(summary.board).filter(x => x >= 2))
    }, [summary])
    const you = summary.players.find(x => x.id === ctl.player)

    useEffect(() => {
        if (you && buyableCompanies.size === 0) {
            const abort = new AbortController();
            apiFetch(`/rooms/${ctl.id}/buy_stock`, {
                method: "POST",
                body: JSON.stringify({ player: ctl.player, buy: [] }),
                signal: abort.signal,
            })
            return () => {
                abort.abort("unmounting");
            }
        }
    }, [ctl.id, ctl.player, you, buyableCompanies])

    if (!you) return <div></div>;
    return (
        <div className="flex flex-col border border-red-500 p-2">
            <div className="pb-2">
                <span className="font-bold text-xl text-red-500">购买股票</span>
            </div>
            <div className="grid grid-cols-1 pb-2" ref={parent}>
                {Object.entries(summary.companies)
                    .filter(([companyId, _]) => buyableCompanies.has(parseInt(companyId)))
                    .map(([companyId, company]) => {
                        const stocks = you.stocks[companyId]
                        const [bg, _fg] = companyColorClasses(companyId, company.color || "")
                        return (
                            <div key={companyId} className={`py-1 flex flex-col`}>
                                <div className="flex flex-row">
                                    <div className={`w-4 h-4 ${bg}`}></div>
                                    <div className="font-bold pl-2 text-sm">{company.name}</div>
                                </div>

                                <div>
                                    <input className="border border-black bg-gray-200 w-full" name={company.name} defaultValue="0" type="number" />
                                </div>
                            </div>
                        )
                    })}
            </div>
            <div>
                <button className="bg-black text-white text-sm rounded-lg px-6 py-2" onClick={() => {
                    const inputs = Array.from(parent.current!.querySelectorAll("input"))
                    const buy: unknown[] = [];
                    for (const input of inputs) {
                        buy.push({ company: input.name, amount: parseInt(input.value) })
                    }
                    apiFetch(`/rooms/${ctl.id}/buy_stock`, {
                        method: "POST",
                        body: JSON.stringify({ player: ctl.player, buy })
                    }).catch(e => {
                        alert(`buy_stock: ${e}`)
                    })
                }}>购买</button>
            </div>
        </div>
    )
}