// e.g. 1A, 3C
export type Card = `${number}${string}`

export interface RoomSummary {
    room_id: string;
    board: Record<Card, number>;
    players: Player[];
    companies: Record<string, Company>;
    distributing: string[];
    acquired_companies: number[];
    status: GameStatus;
}

export interface Player {
    id: string;
    balance: number;
    cards: Card[];
    stocks: Record<string, number>;
}

export type GameStatus = "initializing" | "placing" | "buying" | "distributing" | "finished";

export interface Company {
    name: string;
    cliff: number;
    color?: string;
}