import { Card } from "./types";

export interface DecodedSheet {
    rows: number;
    cols: number;

    // rows/cols
    matrixRC: number[][];
}

const rowAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

export function decodeSheet(b: Record<Card, number>): DecodedSheet {
    const allColNumbers = Object.keys(b).map(x => parseInt(x.substring(0, x.length - 1)))
    const cols = allColNumbers.reduce((a, b) => Math.max(a, b))

    const allRowNumbers = Object.keys(b).map(x => rowAlphabet.indexOf(x[x.length - 1]))
    const rows = allRowNumbers.reduce((a, b) => Math.max(a, b)) + 1

    const ret: DecodedSheet = {
        rows, cols, matrixRC: []
    };

    for (let i = 0; i < rows; i++) {
        const row: number[] = [];
        for (let j = 0; j < cols; j++) {
            row.push(b[`${j + 1}${rowAlphabet[i]}`])
        }
        ret.matrixRC.push(row);
    }
    console.log("decoded sheet", ret)
    return ret
}

export function encodeSheetRC(row: number, col: number): Card {
    return `${col + 1}${rowAlphabet[row]}`
}