local Types = require(script.Parent.Types)

local Court = {}
Court.__index = Court

function Court.new(court: Folder)
    local self = setmetatable({}, Court)

    self.Court = court
    self.Match = nil -- The match assigned to this court, if any

    -- Setup references
    self.CourtGround = court:FindFirstChild("CourtGround") :: Model
    local cg = self.CourtGround

    self.Back1 = cg.Back1 :: Part
    self.Back2 = cg.Back2 :: Part
    self.L1 = cg.L1 :: Part
    self.L2 = cg.L2 :: Part
    self.R1 = cg.R1 :: Part
    self.R2 = cg.R2 :: Part
    self.UL1 = cg.UL1 :: Part
    self.UL2 = cg.UL2 :: Part
    self.UR1 = cg.UR1 :: Part
    self.UR2 = cg.UR2 :: Part

    self.Net = court:FindFirstChild("Net") :: Model
    self.ServeBoxes = court:FindFirstChild("ServeBoxes") :: Model

    local sb = self.ServeBoxes

    self.ServeBox1R = sb.ServeBox1R :: Model
    self.ServeBox1L = sb.ServeBox1L :: Model
    self.ServeBox2R = sb.ServeBox2R :: Model
    self.ServeBox2L = sb.ServeBox2L :: Model

    self.ServeSpots = court:FindFirstChild("ServeSpots") :: Model

    local ss = self.ServeSpots

    self.ServeR1 = ss.R1 :: Part
    self.ServeR2 = ss.R2 :: Part
    self.ServeL1 = ss.L1 :: Part
    self.ServeL2 = ss.L2 :: Part

    -- Return the Court
    return self
end

function Court:AssignMatch(match: Types.Match)
    self.Match = match
end

function Court:ClearMatch()
    self.Match = nil
end

return Court