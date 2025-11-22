-- Types.luau
export type Match = {
    Player1: Player,
    Player2: Player,
    Court: Match?, -- Optional, as a Match may not have a Court assigned
    AssignCourt: (self: Match, court: Court) -> ()
}

export type Court = {
    Court: Folder,
    Occupied: boolean,
    Match: Match?, -- Optional, as a Court may not have a Match assigned
    AssignMatch: (self: Court, match: Match) -> ()
}

return {}