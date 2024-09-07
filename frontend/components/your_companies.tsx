import { companyColorClasses } from "@/utils/colors";
import { apiFetch } from "@/utils/http";
import { Roomctl } from "@/utils/roomctl";
import { useState } from "react";

export default function YourCompanies({ ctl }: { ctl: Roomctl }) {
    const summary = ctl.useSummary();

    /*
    pub fn cliff(size: Int, offset: Int) -> Cliff {
  let level = case size {
    2 -> 2
    3 -> 3
    4 -> 4
    5 -> 5
    x if x >= 6 && x <= 10 -> 6
    x if x >= 11 && x <= 20 -> 7
    x if x >= 21 && x <= 30 -> 8
    x if x >= 31 && x <= 40 -> 9
    x if x >= 41 -> 10
    _ -> panic as { "cliff: unexpected size: " <> int.to_string(size) }
  }
  let level = level + offset
  Cliff(stock_price: 100 * level, bonus: #(
    1000 * level,
    case int.is_odd(level) {
      True -> level * 750 - 50
      False -> level * 750
    },
    500 * level,
  ))
}

    */
    const maxCliff = Object.values(summary.companies).map(x => x.cliff).reduce((a, b) => Math.max(a, b), 0);
    return (
        <div className="flex flex-col bg-black text-white text-xs p-2 font-mono rounded-lg w-full">
            <table className="w-full table-auto">
                <thead>
                    <tr className="text-yellow-300 font-bold">
                        {new Array(maxCliff + 1).fill(0).map((_, cliff) => <th key={"cliff-" + cliff}>
                            <div className="grid grid-flow-row-dense grid-cols-4 gap-1">
                                {Object.entries(summary.companies).filter(x => x[1].cliff === cliff).map(([compId, comp]) => {
                                    const [bg, _] = companyColorClasses(compId, comp.color ?? "")
                                    return (<div key={compId} className={`w-2 h-2 rounded-full ${bg}`}></div>)
                                })}
                            </div>
                        </th>)}
                        <td>股价</td>
                        <td>Top1分红</td>
                        <td>Top2分红</td>
                        <td>Top3分红</td>
                    </tr>
                </thead>
                <tbody>
                    {
                        new Array(11).fill(0).map((_, i) => i + 2).map(level => {
                            const [bonus1, bonus2, bonus3] = levelBonus(level)
                            return (
                                <tr key={"level-" + level}>
                                    {new Array(maxCliff + 1).fill(0).map((_, cliff) => <td key={"cliff-" + cliff}>
                                        {level2size(level - cliff)}
                                    </td>)}
                                    <td>${level * 100}</td>
                                    <td>${bonus1}</td>
                                    <td>${bonus2}</td>
                                    <td>${bonus3}</td>
                                </tr>
                            )
                        }
                        )
                    }
                </tbody>

            </table>
        </div>
    )
}

function levelBonus(level: number): [number, number, number] {
    return [1000 * level, level % 2 === 1 ? level * 750 - 50 : level * 750, 500 * level];
}

function size2level(size: number): number {
    if (size === 2) return 2;
    if (size === 3) return 3;
    if (size === 4) return 4;
    if (size === 5) return 5;
    if (size >= 6 && size <= 10) return 6;
    if (size >= 11 && size <= 20) return 7;
    if (size >= 21 && size <= 30) return 8;
    if (size >= 31 && size <= 40) return 9;
    if (size >= 41) return 10;
    return 0;
}

function level2size(level: number): string {
    if (level === 2) return "2";
    if (level === 3) return "3";
    if (level === 4) return "4";
    if (level === 5) return "5";
    if (level === 6) return "6-10";
    if (level === 7) return "11-20";
    if (level === 8) return "21-30";
    if (level === 9) return "31-40";
    if (level === 10) return "41+";
    return "";
}