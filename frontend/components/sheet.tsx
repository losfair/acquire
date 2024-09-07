import { companyColorClasses } from "@/utils/colors";
import { decodeSheet, encodeSheetRC } from "@/utils/sheet_util";
import { Card, Company } from "@/utils/types";
import { useMemo } from "react";

export default function Sheet({ sheet, companies }: { sheet: Record<Card, number>, companies: Record<string, Company> }) {
    const { rows, cols, matrixRC } = useMemo(() => decodeSheet(sheet), [sheet])

    return (
        <div>
            <div className="grid gap-1 lg:gap-2 font-mono select-none" style={{ gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))` }}>
                {matrixRC.map((row, rowIndex) =>
                    row.map((companyId, colIndex) => {
                        const [bg, fg] = companyColorClasses("" + companyId, companies["" + companyId]?.color || "")
                        const card = encodeSheetRC(rowIndex, colIndex);
                        return (
                            <div key={`${rowIndex}-${colIndex}`} className={`border p-1 text-xs lg:p-2 lg:text-lg text-center ${bg} rounded-lg`}>
                                <span className={`font-bold ${fg}`}>{card}</span>
                            </div>
                        )
                    })
                )}
            </div>
        </div >
    )
}