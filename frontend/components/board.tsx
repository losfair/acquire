import { decodeSheet } from "@/utils/sheet_util";
import { Roomctl } from "@/utils/roomctl";
import { Card, Player } from "@/utils/types";
import { useMemo, useState } from "react";
import Sheet from "./sheet";
import YourCards from "./your_cards";
import Buy from "./buy";
import Waitroom from "./waitroom";
import PlayerInfo from "./player_info";
import Sell from "./sell";
import YourCompanies from "./your_companies";

export default function Board({ ctl }: { ctl: Roomctl }) {
    const summary = ctl.useSummary();
    const { board, players, distributing, companies, status } = summary;
    const { cols } = useMemo(() => decodeSheet(board), [board]);;

    return (
        <div className="container top-0 left-0 p-2 lg:p-4 lg:pt-12 pt-8">
            <div className="flex flex-col max-w-5xl mx-auto">
                <div className="flex flex-col lg:flex-row gap-8">
                    <div className="row-span-3 justify-center">
                        <div className="mx-auto" style={{
                            maxWidth: `${cols * 60}px`,
                        }}>
                            <Sheet sheet={board} companies={companies} />
                        </div>
                    </div>
                    <div className="block lg:hidden">
                        <YourCards ctl={ctl} />
                    </div>
                    <div className="flex flex-col gap-2 lg:max-w-80 p-2 lg:p-0">
                        {status === "buying" && players[0]?.id === ctl.player && <Buy ctl={ctl} />}
                        {status === "distributing" && distributing[0] === ctl.player && <Sell ctl={ctl} />}
                        {status === "initializing" && <Waitroom ctl={ctl} />}
                        <PlayerInfo summary={summary} me={ctl.player} />
                    </div>
                    <div className="grow"></div>
                </div>
                <div className="flex flex-col lg:flex-row pt-2 lg:pt-8 gap-2">
                    <div className="hidden lg:block">
                        <YourCards ctl={ctl} />
                    </div>
                    <div className="lg:grow"></div>
                    <div>
                        <YourCompanies ctl={ctl} />
                    </div>
                </div>
            </div>

        </div>
    );
}