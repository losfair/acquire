import { companyColorClasses } from "@/utils/colors";
import { apiFetch } from "@/utils/http";
import { Roomctl } from "@/utils/roomctl";
import { RoomSummary } from "@/utils/types";
import { useMemo, useState } from "react";

const CardSelected = (
    { summary, card, needCompany, mergeCandidates, disabled, selectedCompany, onClose, onPlace, onDrop, setSelectedCompany }:
        { summary: RoomSummary, card: string, needCompany: string, mergeCandidates: number[], disabled: boolean, selectedCompany: string, onClose: () => void, onPlace: () => void, onDrop: () => void, setSelectedCompany: (x: string) => void }) => {

    const needCompanyForCreate = needCompany === "need_company_for_create"
    const unusedCompanies = useMemo(() => {
        if (!needCompanyForCreate) return [];
        const used = new Set(Object.values(summary.board));
        return Object.entries(summary.companies).filter(([k]) => !used.has(parseInt(k)));
    }, [summary, needCompanyForCreate]);
    const mergeCandidatesInfo = useMemo(() => {
        if (!mergeCandidates.length) return [];
        const set = new Set(mergeCandidates)
        return Object.entries(summary.companies).filter(([k]) => set.has(parseInt(k)));
    }, [summary, mergeCandidates])
    const companyList = needCompanyForCreate ? unusedCompanies : mergeCandidatesInfo;

    if (!card) return null;

    return (
        <div className="fixed inset-0 flex items-center justify-center">
            <div className="bg-white rounded-lg border border-gray-600 p-6 w-full max-w-xl">
                <h2 className="text-xl font-semibold mb-4">{card}</h2>
                {needCompany !== "" &&
                    <>
                        <p className="pb-4">{needCompanyForCreate ? "选择要创建的公司" : "哪一家公司应该成为收购方？"}</p>
                        <div className="grid grid-cols-3 lg:grid-cols-5 gap-4 pb-4">
                            {companyList.map(([companyId, company]) => {
                                const [bg, fg] = companyColorClasses(companyId, company.color || "")
                                return (
                                    <div
                                        key={companyId}
                                        className={`flex flex-col w-24 py-2 items-center border rounded-lg cursor-pointer${selectedCompany === company.name ? " border border-blue-500" : ""}`}
                                        onClick={() => {
                                            setSelectedCompany(company.name);
                                        }}
                                    >
                                        <div className={`w-4 h-4 ${bg}`}></div>
                                        <span className="font-mono text-sm">{company.name}</span>
                                    </div>
                                )
                            })}
                        </div>
                    </>
                }
                <div className={`flex justify-end space-x-2${disabled ? " opacity-50" : ""}`}>
                    <button
                        className="px-4 py-2 bg-black text-white rounded"
                        onClick={disabled ? undefined : onPlace}
                    >
                        放置
                    </button>
                    <button
                        className="px-4 py-2 bg-orange-500 text-white rounded"
                        onClick={disabled ? undefined : onDrop}
                    >
                        丢弃
                    </button>
                    <button
                        className="px-4 py-2 bg-gray-500 text-white rounded"
                        onClick={disabled ? undefined : onClose}
                    >
                        取消
                    </button>
                </div>
            </div>
        </div>
    );
};

export default function YourCards({ ctl }: { ctl: Roomctl }) {
    const summary = ctl.useSummary();
    const [selectedCard, setSelectedCard] = useState("")
    const [needCompany, setNeedCompany] = useState("")
    const [mergeCandidates, setMergeCandidates] = useState([] as number[])
    const [selectedCompany, setSelectedCompany] = useState("");
    const [working, setWorking] = useState(false);

    const you = summary.players.find(x => x.id === ctl.player)
    if (!you) return <div></div>

    const yourTurn = summary.players[0]?.id === you.id && summary.status === "placing";
    const btnClass = `w-12 h-12 pt-2 font-bold text-xl bg-black text-white font-mono text-center rounded-lg select-none cursor-pointer`;

    return (
        <div className="flex flex-col">
            <div className={`flex flex-row items-center justify-center gap-2 lg:gap-4${yourTurn ? "" : " opacity-50"}`}>
                {you.cards.map((card) => (
                    <div
                        key={card}
                        className={btnClass}
                        onClick={() => {
                            if (!yourTurn) return;
                            setSelectedCard(card);
                            setNeedCompany("");
                            setMergeCandidates([]);
                            setSelectedCompany("");
                        }}
                    >
                        <span>{card}</span>
                    </div>
                ))}
                {you.cards.length === 0 && <div className={btnClass.replaceAll("bg-black", "bg-blue-500")} onClick={() => {
                    if (!yourTurn) return;

                    setWorking(true);
                    apiFetch(`/rooms/${ctl.id}/place_card`, {
                        method: "POST", body: JSON.stringify({
                            player: ctl.player,
                            card: "0A",
                            company: "",
                        })
                    }).catch(e => {
                        setSelectedCard("")
                        alert(`place_card: ${e}`);
                    }).finally(() => {
                        setWorking(false);
                    });
                }}>SKIP</div>}
                <div className={btnClass.replaceAll("bg-black", "bg-red-500")} onClick={() => {
                    apiFetch(`/rooms/${ctl.id}/end_game`, {
                        method: "POST",
                        body: JSON.stringify({ player: ctl.player })
                    }).catch(e => {
                        alert(`end_game: ${e}`)
                    })
                }}><span>END</span>
                </div>
            </div>
            <CardSelected summary={summary} card={selectedCard} needCompany={needCompany} mergeCandidates={mergeCandidates} disabled={working} selectedCompany={selectedCompany} onClose={() => {
                setSelectedCard("")
            }} onPlace={() => {
                setWorking(true);
                apiFetch(`/rooms/${ctl.id}/place_card`, {
                    method: "POST", body: JSON.stringify({
                        player: ctl.player,
                        card: selectedCard,
                        company: selectedCompany,
                    })
                }).then(async res => {
                    const { status, candidates } = await res.json();
                    if (status === "need_company" || status === "need_company_for_create" || status === "need_company_for_merge") {
                        setNeedCompany(status);
                        setMergeCandidates(candidates ?? []);
                    } else {
                        setSelectedCard("");
                    }
                }).catch(e => {
                    setSelectedCard("")
                    alert(`place_card: ${e}`);
                }).finally(() => {
                    setWorking(false);
                });
            }} onDrop={() => {
                apiFetch(`/rooms/${ctl.id}/drop_card`, {
                    method: "POST", body: JSON.stringify({
                        player: ctl.player,
                        card: selectedCard,
                    })
                }).catch(e => {
                    alert(`drop_card: ${e}`);
                });
                setSelectedCard("")
            }} setSelectedCompany={setSelectedCompany} />
        </div >
    )
}