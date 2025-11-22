--------------------
-- Services
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--------------------
-- Setup
local songsFolder = SoundService:WaitForChild("Songs")
local soundGroup = songsFolder:WaitForChild("SoundGroup") -- this is where your sounds live

-- Create or grab CurrentSong StringValue
local currentSongValue = ReplicatedStorage:FindFirstChild("CurrentSong")
if not currentSongValue then
	currentSongValue = Instance.new("StringValue")
	currentSongValue.Name = "CurrentSong"
	currentSongValue.Parent = ReplicatedStorage
end

--------------------
-- Config
local fadeTime = 12 -- seconds to fade in/out
local targetVolume = 0.3 -- final volume of songs

--------------------
-- Helpers
local function fadeVolume(sound, startVol, endVol, duration)
	sound.Volume = startVol
	local tween = TweenService:Create(
		sound,
		TweenInfo.new(duration, Enum.EasingStyle.Linear),
		{ Volume = endVol }
	)
	tween:Play()
end

local function shuffle(t)
	for i = #t, 2, -1 do
		local j = math.random(i)
		t[i], t[j] = t[j], t[i]
	end
end

--------------------
-- Main loop
--------------------
local MUSIC_ON = true

if MUSIC_ON then
	while true do
		-- make a fresh shuffled copy of the sounds in SoundGroup
		local playlist = {}
		for _, s in ipairs(soundGroup:GetChildren()) do
			if s:IsA("Sound") then
				table.insert(playlist, s)
			end
		end
		shuffle(playlist)

		-- play through shuffled list forever
		for _, sound in ipairs(playlist) do
			-- set CurrentSong value
			currentSongValue.Value = sound.Name

			-- prepare sound
			sound.Volume = 0
			sound.TimePosition = 0
			sound:Play()

			-- fade in
			fadeVolume(sound, 0, targetVolume, fadeTime)

			-- wait until it's time to fade out
			local playTime = sound.TimeLength - (fadeTime * 2)
			if playTime > 0 then
				task.wait(playTime)
			end

			-- fade out
			fadeVolume(sound, targetVolume, 0, fadeTime)
			task.wait(fadeTime)

			sound:Stop()
		end
	end
end
