rollout JSONBlockReplacer "MH2 Particle Conversion Tool 1.2" width:880 height:1000 (
    group "Folder Selection" (
        button btnSelectInput "Select Input Folder" width:160 across:2 align:#center
        edittext edtInputPath "" readOnly:true width:440 height:20 align:#center
        
        button btnSelectOutput "Select Output Folder" width:160 across:2 align:#center
        edittext edtOutputPath "" readOnly:true width:440 height:20 align:#center
    )
    
    group "Processing" (
        button btnStart "Start Transfer" width:180 height:30 enabled:false across:2
        checkbox chkBackup "Create Backup (.bak)" checked:true align:#left
		label lblprocessinfo "Transfer all particle data from input to output (requires matching folder names)" align:#left	
    )

    /* ===== Analysis / Convert ===== */
    group "Analysis / Convert" (
        -- shared filter for Analyze / Convert / Purge
        dropdownlist ddlFilter "Filter:" items:#("All","USE","DAMAGE","DIE") selection:1 width:160 align:#left

        dropdownlist ddlAnalyzeSource "Analyze from:" items:#("Input","Output") selection:1 width:180 align:#left
        button btnAnalyze "Analyze Particles" width:180 height:26 enabled:false align:#left
        button btnExport "Export Analysis (.txt)" width:180 height:26 enabled:false align:#left

        dropdownlist ddlConvertSource "Convert in:" items:#("Input","Output") selection:1 width:180 align:#left
        checkbox chkToPC "PC" checked:true align:#left
        checkbox chkToConsole "Console" checked:false align:#left
        button btnConvert "Convert Particles" width:180 height:28 enabled:false align:#left
        label lblConvNote "Converts only blood/lblood; updates unknownParticleName accordingly. Respects filter." align:#left
    )

    /* ===== Purge ===== */
    group "Purge Particle Data" (
        dropdownlist ddlPurgeSource "Purge in:" items:#("Input","Output") selection:1 width:180 align:#left
        button btnPurge "Purge Particle Data" width:180 height:28 enabled:false align:#left
        label lblPurgeNote "Removes particle data and restores no-particle layout. Respects filter." align:#left
    )
    /* =================== */
    
    group "Progress" (
        progressBar prgProgress "Progress" width:520 height:20 align:#center
        label lblRemaining "Remaining: --:--:--" align:#left
        label lblTimeTaken "Time taken: --:--:--" align:#left
    )
    
    -- RichTextBox for colored output
    dotNetControl dnLog "System.Windows.Forms.RichTextBox" height:280 width:840 align:#center
	
    label lblCredit "Coded by Hellwire/WhoIsPrice" align:#center 
	
	-- Global Variables 
    local inputFolder = ""
    local outputFolder = ""
    local startPattern = #("\"unknown5\": \"00004040\",", "\"entry\": [")
    local endPattern   = #("}", "]", "}")
    local startTime = 0

    -- For export
    local analysisReport = #() -- plain text lines gathered during analysis

    -- ETA/Progress state
    local fileWeights = #()      -- per-file byte weights (input+output)
    local totalBytes  = 0        -- sum of all weights
    local processedBytes = 0     -- bytes processed so far
    local emaSecPerByte = undefined  -- exponential moving average of seconds/byte
    local lastFileStartTS = 0    -- per-file start timestamp

    /* ===== Logging helpers (colorized) ===== */
    fn rtColor r g b = (dotNetClass "System.Drawing.Color").FromArgb r g b
    local colText   = rtColor 235 235 235
    local colDim    = rtColor 160 160 160
    local colHdr    = rtColor  80 200 255
    local colPC     = rtColor 120 220 120
    local colCon    = rtColor 245 200  80
    local colMix    = rtColor 200 120 255
    local colWarn   = rtColor 255 120 120
    local colInfo   = rtColor 180 220 255

    fn appendLogColor msg color =
    (
        dnLog.SelectionStart = dnLog.TextLength
        dnLog.SelectionLength = 0
        dnLog.SelectionColor = color
        dnLog.AppendText msg
        dnLog.SelectionColor = colText
        dnLog.ScrollToCaret()
    )
    fn appendLog msg = ( appendLogColor msg colText )
	fn logLine msg color:(undefined) =
	(
		if color == undefined then appendLog (msg + "\r\n") else appendLogColor (msg + "\r\n") color
	)
    fn appendTaggedLine clsTag clsColor fileName pcH conH =
    (
        appendLogColor clsTag clsColor
        appendLogColor (" " + fileName + "  ") colText
        appendLogColor ("(pcHits:" + (pcH as string) + ", conHits:" + (conH as string) + ")\r\n") colDim
    )
    fn reportAdd s = ( append analysisReport s )
    /* ======================================= */

    -- Helper function to format time in seconds to HH:MM:SS
    fn formatTime seconds = (
        local s = amax 0 seconds
        local hours = (s / 3600) as integer
        local mins = ((s - (hours * 3600)) / 60) as integer
        local secs = (s - (hours * 3600) - (mins * 60)) as integer
        (formattedPrint hours format:"02d") + ":" + (formattedPrint mins format:"02d") + ":" + (formattedPrint secs format:"02d")
    )
    
    fn normalizePath path = (trimRight (path as string) "\\")
    fn max2 a b = if a > b then a else b
    
    -- Safer getFileSize
    fn safeGetFileSize fpath = (
        local sz = 0
        try ( sz = getFileSize fpath ) catch ( sz = 0 )
        if sz < 0 do sz = 0
        sz
    )
    
    -- Recursive function to get all JSON files
    fn getAllJsonFiles rootDir = (
        local files = #()
        join files (getFiles (rootDir + "\\*.json"))
        local subDirs = getDirectories (rootDir + "\\*")
        for dir in subDirs do join files (getAllJsonFiles dir)
        files
    )

    /* ========= File filtering by animation kind ========= */
	-- Return the filename (no extension), normalized for filtering:
	--  - take everything AFTER the last '#'
	--  - uppercase, so checks are case-insensitive
	fn coreAnimNameFromPath fpath =
	(
		local base = toUpper (getFilenameFile (filenameFromPath fpath))
		local parts = filterString base "#"
		if parts.count > 0 then (parts[parts.count]) else base
	)

	-- Filter: 1=All, 2=USE, 3=DAMAGE, 4=DIE
	fn filenameMatchesFilter fpath filterIndex =
	(
		local core = coreAnimNameFromPath fpath   -- e.g. "BAT_USE_EXECUTE"
		case filterIndex of (
			1: true
			2: (matchPattern core pattern:"BAT_USE*")
			3: (matchPattern core pattern:"BAT_DAMAGE*")
			4: (matchPattern core pattern:"BAT_DIE*")
			default: true
		)
	)

	-- Use this to gather matching files (recursive)
	fn getFilteredJsonFiles rootDir filterIndex =
	(
		local all = getAllJsonFiles rootDir
		local out = #()
		for f in all do if filenameMatchesFilter f filterIndex do append out f
		out
	)
    /* ==================================================== */
    
    fn findPatternInLines lines patternArray = (
        for i = 1 to (lines.count - patternArray.count + 1) do (
            local match = true
            for p = 1 to patternArray.count while match do (
                local line = trimLeft (trimRight lines[i + p - 1])
                if line != patternArray[p] do match = false
            )
            if match do return i
        )
        0
    )

    -- Find a single line equal to a needle (trim-insensitive)
    fn findLineEq lines needle = (
        for i = 1 to lines.count do (
            if (trimLeft (trimRight lines[i])) == needle do return i
        )
        0
    )
    
    fn updateButtonState = (
        btnStart.enabled = (inputFolder != "" and outputFolder != "")
        -- Analysis enable
        local srcSelA = ddlAnalyzeSource.selection
        if srcSelA == 1 then ( btnAnalyze.enabled = (inputFolder  != "") ) else ( btnAnalyze.enabled = (outputFolder != "") )
        btnExport.enabled = (analysisReport.count > 0)
        -- Conversion enable
        local srcSelC = ddlConvertSource.selection
        if srcSelC == 1 then ( btnConvert.enabled = (inputFolder  != "") ) else ( btnConvert.enabled = (outputFolder != "") )
        -- Purge enable
        local srcSelP = ddlPurgeSource.selection
        if srcSelP == 1 then ( btnPurge.enabled = (inputFolder  != "") ) else ( btnPurge.enabled = (outputFolder != "") )
    )
    
    fn extractBlock lines startPattern endPattern = (
        local startIdx = findPatternInLines lines startPattern
        if startIdx == 0 do ( return #() )
        local endIdx = findPatternInLines lines endPattern
        if endIdx == 0 do ( return #() )
        for i = startIdx to (endIdx + endPattern.count - 1) collect lines[i]
    )
    
	fn unitePathFolders folders = (
        if folders.count == 0 do return ""
        local path = folders[1]
        for i = 2 to folders.count do path += "\\" + folders[i]
        path
    )
	
    fn removeNumericPrefix path = (
        local folders = filterString path "\\"
        for i = 1 to folders.count do (
            local folder = folders[i]
            if matchPattern folder pattern:"*#*" then (
                local parts = filterString folder "#"
                if parts.count == 2 then (
                    local isNumber = true
                    try (parts[1] as integer) catch (isNumber = false)
                    if isNumber do folders[i] = parts[2]
                )
            )
        )
        (unitePathFolders folders)
    )
    
    fn findMatchingOutputFile inputFile inputFolder outputFolder = (
        local inputRelPath = trimLeft (substituteString inputFile inputFolder "") "\\"
        local cleanRelPath = removeNumericPrefix inputRelPath
        local allOutputFiles = getAllJsonFiles outputFolder
        for f in allOutputFiles do (
            local outputRelPath = trimLeft (substituteString f outputFolder "") "\\"
            local cleanOutputPath = removeNumericPrefix outputRelPath
            if cleanOutputPath == cleanRelPath do return f
        )
        undefined
    )

    -- Find last closing brace "}" (assumes it's the root object's end)
    fn findInsertionIndex lines =
    (
        for i = lines.count to 1 by -1 do (
            local t = trimLeft (trimRight lines[i])
            if t == "}" do return i
        )
        (lines.count + 1) -- fallback
    )

    -- Ensure the line before a given index ends with a comma, when appropriate
    fn ensureCommaBefore lines idx =
    (
        local j = idx - 1
        while j >= 1 and (trimLeft (trimRight lines[j])) == "" do j -= 1
        if j >= 1 do (
            local t  = trimRight lines[j]
            local tt = trimLeft (trimRight t)
            if (matchPattern t pattern:"*,") == false and tt != "{" and tt != "[" do (
                lines[j] = t + ","
            )
        )
    )

    -- Safety: if the very end has two consecutive non-empty "}" lines, drop the last one
    fn dedupeTrailingRootBrace lines =
    (
        local lastIdx = 0
        for i = lines.count to 1 by -1 do (
            if (trimLeft (trimRight lines[i])) != "" do ( lastIdx = i; exit )
        )
        if lastIdx > 1 do (
            local prevIdx = 0
            for i = (lastIdx - 1) to 1 by -1 do (
                if (trimLeft (trimRight lines[i])) != "" do ( prevIdx = i; exit )
            )
            if prevIdx > 0 do (
                local a = trimLeft (trimRight lines[prevIdx])
                local b = trimLeft (trimRight lines[lastIdx])
                if a == "}" and b == "}" do ( deleteItem lines lastIdx )
            )
        )
        lines
    )

    /* ==============================
       ===== OPTIMIZED ANALYZER =====
       ============================== */

    -- Simple token helpers
    fn hasToken line token = ((findString line token) != undefined)
    fn hasAnyToken line tokens =
    (
        for t in tokens do if (findString line t) != undefined do return true
        false
    )

    -- Count "\u0000" escapes inside a string
    fn countNullEscapes s =
    (
        local count = 0
        local rest = s
        local pos = findString rest "\\u0000"
        while pos != undefined do
        (
            count += 1
            local nextStart = pos + 6
            rest = substring rest nextStart (rest.count - nextStart + 1)
            pos = findString rest "\\u0000"
        )
        count
    )

    -- Return # of \u0000 in *unknownParticleName* value on this line (0 if not present)
    fn unknownNullsOnLine line =
    (
        local keyPos = findString line "\"unknownParticleName\""
        if keyPos == undefined do return 0
        local tail = substring line keyPos (line.count - keyPos + 1)
        local colonPos = findString tail ":"
        if colonPos == undefined do return 0
        local afterColon = substring tail (colonPos + 1) (tail.count - colonPos)
        local firstQ = findString afterColon "\""
        if firstQ == undefined do return 0
        local afterFirstQ = substring afterColon (firstQ + 1) (afterColon.count - firstQ)
        local secondQ = findString afterFirstQ "\""
        if secondQ == undefined do return 0
        local value = substring afterFirstQ 1 (secondQ - 1)
        countNullEscapes value
    )

    -- Tail streaming scanner: reads only the last N bytes
    fn analyzeFileTail fpath tailBytes:524288 =
    (
        local pcParticles = #(
            "_flash_", "lblood", "lblood1","lblood2","lblood3","lblood4","lblood5","lblood6","lblood7","lblood8",
            "lblooda","lbloodb","lbloodc","lbloodd","lbloode","lbloodf","lbloodg","lbloodh","lbloodi","lbloodj","lbloodk","lbloodm",
            "barx02","loil","lsmoke","beaterh","beaterq","bladeq","bladeh","fistsh","fistsq"
        )
        local consoleParticles = #(
            "blood","blood1","blood2","blood3","blood4","blood5","blood6","blood7","blood8",
            "mangler","burnfla","drumexpl","gunshot_smoke","sprink03"
        )

        local pcHits = 0
        local conHits = 0

        local lb_total = 0
        local lb_ok    = 0
        local lb_wrong = #()

        local bl_total = 0
        local bl_ok    = 0
        local bl_wrong = #()

        local pendings = #()   -- #(expectedNulls, resolved)
        local pendingTTL = #()
        local PENDING_SCAN_LINES = 40

        local f = openFile fpath mode:"rt"
        if f == undefined do (return undefined)

        local size = safeGetFileSize fpath
        local startPos = amax 0 (size - tailBytes)
        seek f startPos
        if startPos > 0 do ( ignore = readLine f ) -- discard partial first line

        local line

        while not eof f do
        (
            line = readLine f
            if line == undefined do exit

            local hasLB = hasToken line "lblood"
            if hasLB do pcHits += 1
            if (hasAnyToken line consoleParticles) do
            (
                if (hasToken line "blood") and hasLB then ()
                else conHits += 1
            )

            -- open pendings
            if hasLB then
            (
                lb_total += 1
                append pendings #(1, false) -- expect single \u0000
                append pendingTTL PENDING_SCAN_LINES
            )
            else if ((hasToken line "blood") and (not hasLB)) then
            (
                bl_total += 1
                append pendings #(2, false) -- expect double \u0000
                append pendingTTL PENDING_SCAN_LINES
            )

            -- resolve only on unknownParticleName line
            local cnt = unknownNullsOnLine line
            if cnt > 0 do
            (
                if cnt <= 2 then
                (
                    for i = 1 to pendings.count do
                    (
                        if pendings[i][2] == false do
                        (
                            local expected = pendings[i][1]
                            if expected == 1 then
                            (
                                if cnt == 1 then ( lb_ok += 1 ) else ( append lb_wrong "two-null" )
                            )
                            else if expected == 2 then
                            (
                                if cnt == 2 then ( bl_ok += 1 ) else ( append bl_wrong "one-null" )
                            )
                            pendings[i][2] = true
                            exit
                        )
                    )
                )
                -- cnt > 2: ignore (blank/sentinel entries)
            )

            -- close/expire pendings
            local closeNow = (findString line "}") != undefined
            for j = pendings.count to 1 by -1 do
            (
                if pendings[j][2] == false then
                (
                    pendingTTL[j] -= 1
                    if closeNow or pendingTTL[j] <= 0 then
                    (
                        local expected = pendings[j][1]
                        if expected == 1 then append lb_wrong "missing-unknownParticleName"
                        else append bl_wrong "missing-unknownParticleName"
                        deleteItem pendings j
                        deleteItem pendingTTL j
                    )
                )
                else
                (
                    deleteItem pendings j
                    deleteItem pendingTTL j
                )
            )
        )
        close f

        local cls = if (pcHits > 0 and conHits == 0) then "PC/Wii"
            else if (conHits > 0 and pcHits == 0) then "Console"
            else if (pcHits == 0 and conHits == 0) then "Unknown"
            else "Mixed"

        #(
            cls, pcHits, conHits,
            lb_total, lb_ok, lb_wrong,
            bl_total, bl_ok, bl_wrong
        )
    )

    -- Streaming/tail analyzer that iterates over files (with filter)
    fn analyzeParticles rootDir =
    (
        if rootDir == "" do ( logLine "ERROR: No folder selected for analysis." color:colWarn; return false )
		local filterIdx = ddlFilter.selection
		local files = getFilteredJsonFiles rootDir filterIdx
        if files.count == 0 do ( logLine ("No JSON files found in: " + rootDir) color:colWarn; return false )

        analysisReport = #() -- reset
        btnExport.enabled = false

        logLine "================================================" color:colHdr
        logLine ("Analyzing particles in: " + rootDir) color:colInfo
		logLine ("Filter: " + ddlFilter.items[filterIdx]) color:colInfo
        logLine ("Files: " + (files.count as string)) color:colInfo
        logLine "------------------------------------------------" color:colHdr

        reportAdd "==== Particle Analysis Report ===="
        reportAdd ("Folder: " + rootDir)
		reportAdd ("Filter: " + ddlFilter.items[filterIdx])
        reportAdd ("Files: " + (files.count as string))
        reportAdd "----------------------------------"

        local nPC = 0
        local nConsole = 0
        local nMixed = 0
        local nMismatches = 0

        for f in files do
        (
            local res = analyzeFileTail f tailBytes:524288 -- 512 KB tail
            if res == undefined then
            (
                logLine ("ERROR: Could not read " + (filenameFromPath f)) color:colWarn
                reportAdd ("ERROR: " + (filenameFromPath f))
                continue
            )

            local cls  = res[1]
            local pcH  = res[2]
            local conH = res[3]
            local lb_t = res[4]
            local lb_o = res[5]
            local lb_w = res[6]
            local bl_t = res[7]
            local bl_o = res[8]
            local bl_w = res[9]

            case cls of (
                "PC/Wii": (nPC += 1)
                "Console": (nConsole += 1)
                "Mixed": (nMixed += 1)
                default: ()
            )

            local mismHere = (lb_t - lb_o) + (bl_t - bl_o)
            nMismatches += mismHere

            local clsTag = case cls of (
                "PC/Wii": "[PC]     "
                "Console": "[CONSOLE]"
                "Mixed":   "[MIXED]  "
                default:   "[?]      "
            )
            local clsColor = case cls of (
                "PC/Wii": colPC
                "Console": colCon
                "Mixed": colMix
                default: colText
            )

            appendTaggedLine clsTag clsColor (filenameFromPath f) pcH conH
            reportAdd (clsTag + " " + (filenameFromPath f) + "  (pcHits:" + (pcH as string) + ", conHits:" + (conH as string) + ")")

            if (lb_t > 0 or bl_t > 0) do
            (
                appendLogColor ("   lblood: total " + (lb_t as string) + ", ok " + (lb_o as string)) colText
                if (lb_t - lb_o) > 0 do appendLogColor ("  -> mismatches: " + ((lb_t - lb_o) as string)) colWarn
                appendLog "\r\n"

                appendLogColor ("   blood : total " + (bl_t as string) + ", ok " + (bl_o as string)) colText
                if (bl_t - bl_o) > 0 do appendLogColor ("  -> mismatches: " + ((bl_t - bl_o) as string)) colWarn
                appendLog "\r\n"

                local rpt = "   lblood: total " + (lb_t as string) + ", ok " + (lb_o as string)
                if (lb_t - lb_o) > 0 then rpt += ("  -> mismatches: " + ((lb_t - lb_o) as string))
                reportAdd rpt
                rpt = "   blood : total " + (bl_t as string) + ", ok " + (bl_o as string)
                if (bl_t - bl_o) > 0 then rpt += ("  -> mismatches: " + ((bl_t - bl_o) as string))
                reportAdd rpt
            )

            if lb_w.count > 0 do
            (
                logLine ("   WARN lblood wrong unknownParticleName: " + (lb_w as string)) color:colWarn
                reportAdd ("   WARN lblood wrong unknownParticleName: " + (lb_w as string))
            )
            if bl_w.count > 0 do
            (
                logLine ("   WARN blood  wrong unknownParticleName: " + (bl_w as string)) color:colWarn
                reportAdd ("   WARN blood  wrong unknownParticleName: " + (bl_w as string))
            )
        )

        logLine "------------------------------------------------" color:colHdr
        logLine "Summary:" color:colInfo
        logLine ("  PC/Wii files : " + (nPC as string)) color:colPC
        logLine ("  Console files: " + (nConsole as string)) color:colCon
        logLine ("  Mixed files  : " + (nMixed as string)) color:colMix
        logLine ("  Mismatch spots (blood/lblood): " + (nMismatches as string)) color:colWarn
        logLine "Analysis complete." color:colHdr

        append analysisReport "----------------------------------"
        append analysisReport ("Filter: " + ddlFilter.items[filterIdx])
        append analysisReport ("PC/Wii files : " + (nPC as string))
        append analysisReport ("Console files: " + (nConsole as string))
        append analysisReport ("Mixed files  : " + (nMixed as string))
        append analysisReport ("Mismatch spots (blood/lblood): " + (nMismatches as string))
        append analysisReport "Analysis complete."

        btnExport.enabled = (analysisReport.count > 0)
        true
    )
    /* ===== END ANALYZER ===== */

    /* =========================
       ===== CONVERTER =========
       ========================= */

    -- special mapping bloodN -> lbloodX (PC target)
    fn mapBloodToPC name =
    (
        if not (matchPattern name pattern:"blood*") do return undefined
        local suffix = substring name 6 (name.count - 5) -- after "blood"
        case suffix of (
            "1": "lblood4"
            "2": "lblood6"
            "3": "lbloodd"
            "4": "lblood5"
            "5": "lbloode"
            "6": "lbloodk"
            default: ("lblood" + suffix)
        )
    )

    -- inverse mapping lbloodX -> bloodN (Console target)
    fn mapPCToBlood name =
    (
        if not (matchPattern name pattern:"lblood*") do return undefined
        local suffix = substring name 7 (name.count - 6) -- after "lblood"
        case suffix of (
            "4": "blood1"
            "a": "blood2"
            "6": "blood3"
            "5": "blood4"
            "e": "blood5"
            "k": "blood6"
            default: ("blood" + suffix)
        )
    )

    -- returns #(newName, newNulls) or undefined if not a blood/lblood
    -- newNulls: 1 for PC, 2 for Console
    fn convertParticleName oldName targetPC =
    (
        if targetPC then
        (
            if matchPattern oldName pattern:"blood*" then
                #(mapBloodToPC oldName, 1)
            else if matchPattern oldName pattern:"lblood*" then
                #(oldName, 1) -- already PC naming, but enforce single null
            else
                undefined
        )
        else
        (
            if matchPattern oldName pattern:"lblood*" then
                #(mapPCToBlood oldName, 2)
            else if matchPattern oldName pattern:"blood*" then
                #(oldName, 2) -- already Console naming, but enforce double null
            else
                undefined
        )
    )

    -- Build a new 'particleName' line with preserved indentation and comma
    fn buildParticleNameLine srcLine newName =
    (
        local qpos = findString srcLine "\""
        local indent = if qpos != undefined then substring srcLine 1 (qpos-1) else ""
        local hasComma = (matchPattern (trimRight srcLine) pattern:"*,")
        indent + "\"particleName\": \"" + newName + "\"" + (if hasComma then "," else "")
    )

    -- Build a new 'unknownParticleName' line with proper null count, preserved indent/comma
    fn buildUnknownLine srcLine nulls =
    (
        local qpos = findString srcLine "\""
        local indent = if qpos != undefined then substring srcLine 1 (qpos-1) else ""
        local hasComma = (matchPattern (trimRight srcLine) pattern:"*,")
        local val = if nulls == 2 then "\\u0000\\u0000" else "\\u0000"
        indent + "\"unknownParticleName\": \"" + val + "\"" + (if hasComma then "," else "")
    )

    -- Convert all blood/lblood in one JSON file, streaming line-by-line
    fn convertFileParticles fpath targetPC =
    (
        local converted = 0
        local forcedUnknownUpdates = 0
        local skipped = 0
        local errors = 0

        local fin = openFile fpath mode:"rt"
        if fin == undefined do (return #(0,0,0,1)) -- error opening

        local tmpPath = fpath + ".tmp_conv"
        local fout = createFile tmpPath
        if fout == undefined do (close fin; return #(0,0,0,1))

        local pendingNulls = 0 -- 0=none,1=PC,2=Console (to apply on next unknownParticleName)
        local pendingWasConverted = false -- true if name actually changed (vs enforcing unknown only)

        while not eof fin do
        (
            local line = readLine fin
            if line == undefined do exit

            if (findString line "\"particleName\"") != undefined then
            (
                -- Parse current name between quotes after colon
                local colonPos = findString line ":"
                if colonPos != undefined then
                (
                    local afterColon = substring line (colonPos+1) (line.count - colonPos)
                    local firstQ = findString afterColon "\""
                    if firstQ != undefined then
                    (
                        local afterFirstQ = substring afterColon (firstQ+1) (afterColon.count - firstQ)
                        local secondQ = findString afterFirstQ "\""
                        if secondQ != undefined then
                        (
                            local curName = substring afterFirstQ 1 (secondQ - 1)
                            local res = convertParticleName curName targetPC
                            if res != undefined then
                            (
                                local newName = res[1]
                                local wantNulls = res[2]
                                pendingNulls = wantNulls
                                pendingWasConverted = (newName != curName)
                                
                                if pendingWasConverted then
                                (
                                    local newLine = buildParticleNameLine line newName
                                    format "%\r\n" newLine to:fout
                                    converted += 1
                                    continue
                                )
                                else
                                (
                                    -- keep line, but still enforce unknownParticleName later
                                    format "%\r\n" line to:fout
                                    forcedUnknownUpdates += 1
                                    continue
                                )
                            )
                            else
                            (
                                -- Not a blood/lblood
                                format "%\r\n" line to:fout
                                pendingNulls = 0
                                pendingWasConverted = false
                                skipped += 1
                                continue
                            )
                        )
                    )
                )
                -- Fallback if parsing failed
                format "%\r\n" line to:fout
                pendingNulls = 0
                pendingWasConverted = false
                continue
            )
            else if (findString line "\"unknownParticleName\"") != undefined then
            (
                if pendingNulls > 0 then
                (
                    local newLine = buildUnknownLine line pendingNulls
                    format "%\r\n" newLine to:fout
                    pendingNulls = 0
                    pendingWasConverted = false
                    continue
                )
                else
                (
                    -- leave untouched
                    format "%\r\n" line to:fout
                    continue
                )
            )
            else
            (
                -- normal pass-through
                format "%\r\n" line to:fout
            )
        )

        close fin
        close fout

        -- Backup & replace
        if chkBackup.checked then
        (
            local bk = fpath + ".bak"
            copyFile fpath bk
        )
        if not (deleteFile fpath) do (errors += 1)
        if not (renameFile tmpPath fpath) do (errors += 1)

        #(converted, forcedUnknownUpdates, skipped, errors)
    )

    fn convertParticles rootDir targetPC =
    (
        if rootDir == "" do ( logLine "ERROR: No folder selected for conversion." color:colWarn; return false )
		local filterIdx = ddlFilter.selection -- or whatever your filter dropdown is named
		local files = getFilteredJsonFiles rootDir filterIdx
        if files.count == 0 do ( logLine ("No JSON files found in: " + rootDir) color:colWarn; return false )

        logLine "================================================" color:colHdr
        logLine ("Converting particles in: " + rootDir) color:colInfo
        logLine ("Filter: " + ddlFilter.items[filterIdx]) color:colInfo
        logLine ("Target platform: " + (if targetPC then "PC (\\u0000)" else "Console (\\u0000\\u0000)")) color:colInfo
        logLine "------------------------------------------------" color:colHdr

        local totalConv = 0
        local totalForcedU = 0
        local totalSkipped = 0
        local totalErr = 0

        for f in files do
        (
            local res = convertFileParticles f targetPC
            local c = res[1]; local fu = res[2]; local sk = res[3]; local er = res[4]
            totalConv += c; totalForcedU += fu; totalSkipped += sk; totalErr += er

            local tag = if targetPC then "[->PC]    " else "[->CON]   "
            local col = if targetPC then colPC else colCon
            appendLogColor tag col
            appendLogColor (" " + (filenameFromPath f) + "  ") colText
            appendLogColor ("(renamed:" + (c as string) + ", enforcedUnknown:" + (fu as string) + ", skipped:" + (sk as string) + ", errs:" + (er as string) + ")\r\n") colDim
        )

        logLine "------------------------------------------------" color:colHdr
        logLine ("Total renamed: " + (totalConv as string)) color:(if targetPC then colPC else colCon)
        logLine ("Total enforced unknownParticleName: " + (totalForcedU as string)) color:colInfo
        logLine ("Total skipped (non-blood entries seen on particleName lines): " + (totalSkipped as string)) color:colDim
        logLine ("Total errors: " + (totalErr as string)) color:colWarn
        logLine "Conversion complete." color:colHdr

        true
    )

    /* ============= PURGE PARTICLE DATA (filtered) ============= */

    -- Build a minimal no-particle block (keeps the trailing root brace pattern safe)
    fn buildNoParticleBlock =
    (
        local arr = #()
        append arr "\"unknown5\": \"00004040\","
        append arr "\"entry\": []"
        append arr "}"   -- close root (writer will skip original root to avoid dup)
        arr
    )

    -- Purge one file by overwriting from 'unknown5' / 'entry' start to after root with minimal block
    fn purgeFileParticles fpath =
    (
        local lines = #()
        local f = openFile fpath mode:"rt"
        if f == undefined do (return false)
        while not eof f do append lines (readLine f)
        close f

        local idxUnknown5     = findLineEq lines "\"unknown5\": \"00004040\","
        local idxEntryBracket = findLineEq lines "\"entry\": ["
        local idxEntryEmpty1  = findLineEq lines "\"entry\": []"
        local idxEntryEmpty2  = findLineEq lines "\"entry\":[]"
        local idxEntryAny     = if idxEntryBracket != 0 then idxEntryBracket else (if idxEntryEmpty1 != 0 then idxEntryEmpty1 else idxEntryEmpty2)

        if (idxUnknown5 == 0 and idxEntryAny == 0) do (return false) -- nothing to purge

        local startIdx = if (idxUnknown5 != 0 and idxEntryAny != 0) then
            (if idxUnknown5 < idxEntryAny then idxUnknown5 else idxEntryAny)
        else (if idxUnknown5 != 0 then idxUnknown5 else idxEntryAny)

        local rootIdx = findInsertionIndex lines
        ensureCommaBefore lines startIdx

        local newContent = #()
        for j = 1 to (startIdx - 1) do append newContent lines[j]
        join newContent (buildNoParticleBlock())
        for j = (rootIdx + 1) to lines.count do append newContent lines[j]

        newContent = dedupeTrailingRootBrace newContent

        if chkBackup.checked do copyFile fpath (fpath + ".bak")
        local outf = createFile fpath
        if outf == undefined do (return false)
        for L in newContent do format "%\r\n" L to:outf
        close outf
        true
    )

    fn purgeParticles rootDir =
    (
        if rootDir == "" do ( logLine "ERROR: No folder selected for purge." color:colWarn; return false )
		local filterIdx = ddlFilter.selection -- or whatever your filter dropdown is named
		local files = getFilteredJsonFiles rootDir filterIdx
        if files.count == 0 do ( logLine ("No JSON files found in: " + rootDir) color:colWarn; return false )

        logLine "================================================" color:colHdr
        logLine ("Purging particle data in: " + rootDir) color:colInfo
        logLine ("Filter: " + ddlFilter.items[filterIdx]) color:colInfo
        logLine "------------------------------------------------" color:colHdr

        local ok = 0
        local skip = 0
        local err = 0

        for f in files do
        (
            local res = purgeFileParticles f
            if res then
            (
                appendLogColor "[PURGED] " colWarn
                appendLogColor ((filenameFromPath f) + "\r\n") colText
                ok += 1
            )
            else
            (
                appendLogColor "[SKIP]   " colDim
                appendLogColor ((filenameFromPath f) + "\r\n") colText
                skip += 1
            )
        )

        logLine "------------------------------------------------" color:colHdr
        logLine ("Purged: " + (ok as string)) color:colWarn
        logLine ("Skipped: " + (skip as string)) color:colDim
        logLine ("Errors: " + (err as string)) color:colWarn
        logLine "Purge complete." color:colHdr
        true
    )
    /* =========== END PURGE =========== */

    /* ===== ORIGINAL TRANSFER (unchanged) ===== */
    fn processFiles inputPath outputPath = (
        local jsonFiles = getAllJsonFiles inputPath
        local processedCount = 0
        local skippedCount = 0
        local errorCount = 0
        local totalFiles = jsonFiles.count
        
        prgProgress.value = 0
        lblRemaining.caption = "Remaining: Calculating..."
        lblTimeTaken.caption = "Time taken: --:--:--"
        startTime = timeStamp()

        fileWeights = #()
        totalBytes = 0
        processedBytes = 0
        emaSecPerByte = undefined

        for f in jsonFiles do (
            local inSize = safeGetFileSize f
            local outF = findMatchingOutputFile f inputPath outputPath
            local outSize = if outF != undefined then (safeGetFileSize outF) else 0
            local w = inSize + outSize
            if w <= 0 do w = 1
            append fileWeights w
            totalBytes += w
        )
        
        logLine ("Scanning folder: " + inputPath) color:colInfo
        logLine ("Found " + (totalFiles as string) + " JSON files") color:colInfo
        logLine "------------------------------------------------" color:colHdr
        
        for i = 1 to totalFiles do (
            local f = jsonFiles[i]
            local filename = filenameFromPath f

            lastFileStartTS = timeStamp()
            if totalBytes > 0 do prgProgress.value = ((processedBytes as float) / totalBytes * 100.0)
            windows.processPostedMessages()
            
            local outFile = findMatchingOutputFile f inputPath outputPath
            if outFile == undefined do (
                logLine ("ERROR: Output file missing for [" + filename + "]") color:colWarn
                errorCount += 1
                continue
            )
            
            -- Read input
            local inFile = openFile f mode:"rt"
            if inFile == undefined do (
                logLine ("ERROR: Could not read [" + filename + "]") color:colWarn
                errorCount += 1
                continue
            )
            local inputLines = #()
            while not eof inFile do append inputLines (readLine inFile)
            close inFile
            
            local blockLines = extractBlock inputLines startPattern endPattern
            if blockLines.count == 0 do (
                logLine ("SKIPPED: [" + filename + "] (pattern not found in input)") color:colDim
                skippedCount += 1
                processedBytes += fileWeights[i]
                if totalBytes > 0 and emaSecPerByte != undefined do (
                    local remainingBytes = max2 0 (totalBytes - processedBytes)
                    local remainingSec = remainingBytes * emaSecPerByte
                    lblRemaining.caption = "Remaining: " + (formatTime remainingSec)
                    prgProgress.value = ((processedBytes as float) / totalBytes * 100.0)
                )
                continue
            )
            
            -- Read output
            local outFileHandle = openFile outFile mode:"rt"
            if outFileHandle == undefined do (
                logLine ("ERROR: Could not read output [" + filename + "]") color:colWarn
                errorCount += 1
                processedBytes += fileWeights[i]
                continue
            )
            local outputLines = #()
            while not eof outFileHandle do append outputLines (readLine outFileHandle)
            close outFileHandle
            
            local outStartIdxFull = findPatternInLines outputLines startPattern
            local outEndIdxFull   = findPatternInLines outputLines endPattern

            local idxUnknown5     = findLineEq outputLines "\"unknown5\": \"00004040\","
            local idxEntryEmpty1  = findLineEq outputLines "\"entry\": []"
            local idxEntryEmpty2  = findLineEq outputLines "\"entry\":[]"
            local idxEntryEmpty   = (if idxEntryEmpty1 != 0 then idxEntryEmpty1 else idxEntryEmpty2)

            if chkBackup.checked do (
                local backupFile = outFile + ".bak"
                if not copyFile outFile backupFile do logLine ("WARNING: Backup failed for [" + filename + "]") color:colWarn
            )

            local newContent = #()
            if (outStartIdxFull != 0 and outEndIdxFull != 0) then (
                for j = 1 to (outStartIdxFull - 1) do append newContent outputLines[j]
                join newContent blockLines
                for j = (outEndIdxFull + endPattern.count) to outputLines.count do append newContent outputLines[j]
                logLine ("PROCESSED (replaced): [" + filename + "]") color:colPC

            ) else if (idxUnknown5 != 0 or idxEntryEmpty != 0) then (
                local startIdx = if (idxUnknown5 != 0 and idxEntryEmpty != 0) then
                    (if idxUnknown5 < idxEntryEmpty then idxUnknown5 else idxEntryEmpty)
                else
                    (if idxUnknown5 != 0 then idxUnknown5 else idxEntryEmpty)

                local rootIdx = findInsertionIndex outputLines
                ensureCommaBefore outputLines startIdx

                for j = 1 to (startIdx - 1) do append newContent outputLines[j]
                join newContent blockLines
                for j = (rootIdx + 1) to outputLines.count do append newContent outputLines[j]

                logLine ("PROCESSED (fixed partial -> overwrite): [" + filename + "]") color:colPC

            ) else (
                local insertionIdx = findInsertionIndex outputLines
                ensureCommaBefore outputLines insertionIdx

                for j = 1 to (insertionIdx - 1) do append newContent outputLines[j]
                join newContent blockLines
                for j = (insertionIdx + 1) to outputLines.count do append newContent outputLines[j]

                logLine ("PROCESSED (inserted missing block): [" + filename + "]") color:colPC
            )

            newContent = dedupeTrailingRootBrace newContent
            
            local outFileHandle2 = createFile outFile
            if outFileHandle2 == undefined do (
                logLine ("ERROR: Could not write [" + filename + "]") color:colWarn
                errorCount += 1
                processedBytes += fileWeights[i]
                continue
            )
            
            for line in newContent do format "%\r\n" line to:outFileHandle2
            flush outFileHandle2
            close outFileHandle2

            local fileElapsedSec = (timeStamp() - lastFileStartTS) / 1000.0
            local w = fileWeights[i] as float
            local secPerByteNow = fileElapsedSec / (amax 1 w)

            if emaSecPerByte == undefined then
                emaSecPerByte = secPerByteNow
            else
                emaSecPerByte = 0.2 * secPerByteNow + 0.8 * emaSecPerByte

            processedBytes += w

            if totalBytes > 0 do (
                prgProgress.value = ((processedBytes as float) / totalBytes * 100.0)
                local remainingBytes = totalBytes - processedBytes
                if remainingBytes < 0 do remainingBytes = 0
                local remainingSec = remainingBytes * emaSecPerByte
                lblRemaining.caption = "Remaining: " + (formatTime remainingSec)
            )

            processedCount += 1
        )
        
        local totalTime = (timeStamp() - startTime) / 1000.0
        lblTimeTaken.caption = "Time taken: " + (formatTime totalTime)
        if processedBytes >= totalBytes and totalBytes > 0 do lblRemaining.caption = "Remaining: 00:00:00"
        
        logLine "------------------------------------------------" color:colHdr
        logLine ("Processed: " + (processedCount as string) + " files") color:colInfo
        logLine ("Skipped: " + (skippedCount as string) + " files") color:colInfo
        logLine ("Errors: " + (errorCount as string) + " files") color:colInfo
        logLine ("Transfer complete in " + (formatTime totalTime) + "!") color:colHdr
    )
    
    on JSONBlockReplacer open do (
        dnLog.ReadOnly = true
        dnLog.WordWrap = false
        dnLog.ScrollBars = (dotNetClass "System.Windows.Forms.RichTextBoxScrollBars").Both
        dnLog.Font = dotNetObject "System.Drawing.Font" "Consolas" 10
        dnLog.BackColor = (dotNetClass "System.Drawing.Color").FromArgb 10 10 10
		dnLog.ForeColor = colText
    )
    
    on btnSelectInput pressed do (
        local path = getSavePath()
        if path != undefined do (
            inputFolder = normalizePath path
            edtInputPath.text = inputFolder
            updateButtonState()
        )
    )
    
    on btnSelectOutput pressed do (
        local path = getSavePath()
        if path != undefined do (
            outputFolder = normalizePath path
            edtOutputPath.text = outputFolder
            updateButtonState()
        )
    )
    
    on btnStart pressed do (
        dnLog.Text = ""
        logLine "Starting transfer process..." color:colHdr
        appendLog ("Input: " + inputFolder + "\r\n")
        appendLog ("Output: " + outputFolder + "\r\n\r\n")
        processFiles inputFolder outputFolder
    )

    on btnAnalyze pressed do (
        local src = ddlAnalyzeSource.selection
        local root = if src == 1 then inputFolder else outputFolder
        logLine ("Starting particle analysis (" + (if src == 1 then "Input" else "Output") + ")...") color:colHdr
        analyzeParticles root
        updateButtonState()
    )

    on btnExport pressed do (
        if analysisReport.count == 0 then (
            logLine "Nothing to export yet." color:colWarn
        ) else (
            local savePath = getSaveFileName caption:"Save Analysis Report" types:"Text (*.txt)|*.txt|All Files (*.*)|*.*" filename:"particle_analysis.txt"
            if savePath != undefined then (
                local f = createFile savePath
                if f != undefined then (
                    for L in analysisReport do format "%\r\n" L to:f
                    close f
                    logLine ("Saved report to: " + savePath) color:colPC
                ) else (
                    logLine "ERROR: Could not create file." color:colWarn
                )
            )
        )
    )

    on ddlAnalyzeSource selected i do ( updateButtonState() )
    on ddlConvertSource selected i do ( updateButtonState() )
    on ddlPurgeSource selected i do ( updateButtonState() )
    on ddlFilter selected i do ( ) -- shared, no extra work; functions read it

    on chkToPC changed v do ( if v do chkToConsole.checked = false )
    on chkToConsole changed v do ( if v do chkToPC.checked = false )

    on btnConvert pressed do (
        local src = ddlConvertSource.selection
        local root = if src == 1 then inputFolder else outputFolder
        local targetPC = chkToPC.checked
        logLine ("Starting conversion (" + (if src == 1 then "Input" else "Output") + " -> " + (if targetPC then "PC" else "Console") + ")...") color:(if targetPC then colPC else colCon)
        convertParticles root targetPC
        updateButtonState()
    )

    on btnPurge pressed do (
        local src = ddlPurgeSource.selection
        local root = if src == 1 then inputFolder else outputFolder
        logLine ("Starting purge (" + (if src == 1 then "Input" else "Output") + ")...") color:colWarn
        purgeParticles root
        updateButtonState()
    )
)

createDialog JSONBlockReplacer
