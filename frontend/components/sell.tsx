import { companyColorClasses } from "@/utils/colors";
import { apiFetch } from "@/utils/http";
import { Roomctl } from "@/utils/roomctl";
import { useRef, useState } from "react";

export default function Sell({ ctl }: { ctl: Roomctl }) {
    const summary = ctl.useSummary();
    const [selectedCard, setSelectedCard] = useState("")
    const parent = useRef(null as HTMLDivElement | null)

    const you = summary.players.find(x => x.id === ctl.player)
    if (!you) return <div></div>;

    return (
        <div className="flex flex-col border border-red-500 p-4">
            <div className="pb-2">
                <span className="font-bold text-xl text-red-500">出售股票</span>
            </div>
            <div className="grid grid-cols-1" ref={parent}>
                {Object.entries(summary.companies).filter(
                    ([companyId, _]) => summary.acquired_companies.findIndex(x => "" + x === companyId) !== -1
                ).map(([companyId, company]) => {
                    const stocks = you.stocks[companyId]
                    const [bg, _fg] = companyColorClasses(companyId, company.color || "")
                    return (
                        <div key={companyId} className={`pb-2 flex flex-col`}>
                            <div className="flex flex-row">
                                <div className={`w-4 h-4 ${bg}`}></div>
                                <div className="font-bold pl-2 text-sm">{company.name}</div>
                            </div>
                            <input className="border border-black bg-gray-200" name={company.name} defaultValue="0" type="number" />
                        </div>
                    )
                })}
            </div>
            <div>
                <button className="bg-black text-white text-sm rounded-lg px-6 py-2" onClick={() => {
                    const inputs = Array.from(parent.current!.querySelectorAll("input"))
                    const for_money: Record<string, number> = {};
                    for (const input of inputs) {
                        for_money[input.name] = parseInt(input.value)
                    }
                    apiFetch(`/rooms/${ctl.id}/sell_stock`, {
                        method: "POST",
                        body: JSON.stringify({
                            player: ctl.player, sell: {
                                for_money,
                                for_other_stocks: {}
                            }
                        })
                    }).catch(e => {
                        alert(`sell_stock: ${e}`)
                    })
                }}>出售</button>
            </div>
        </div>
    )
}