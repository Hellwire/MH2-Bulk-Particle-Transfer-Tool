rollout JSONBlockReplacer "Particle Data Transfer Tool 1.1" width:850 height:650 (
    group "Folder Selection" (
        button btnSelectInput "Select Input Folder" width:120 across:2 align:#center
        edittext edtInputPath "" readOnly:true width:380 height:20 align:#center
        
        button btnSelectOutput "Select Output Folder" width:120 across:2 align:#center
        edittext edtOutputPath "" readOnly:true width:380 height:20 align:#center
    )
    
    group "Processing" (
        button btnStart "Start Transfer" width:120 height:30 enabled:false 
        checkbox chkBackup "Create Backup (.bak)" checked:true align:#left
    )
    
    group "Progress" (
        progressBar prgProgress "Progress" width:420 height:20 align:#center
        label lblRemaining "Remaining: --:--:--" align:#left
        label lblTimeTaken "Time taken: --:--:--" align:#left
    )
    
    -- .NET TextBox for log with scrollbars
    dotNetControl dnLog "System.Windows.Forms.TextBox" height:350 width:800 align:#center
	
    label lblCredit "Coded by Hellwire/WhoIsPrice" align:#center offset:[0,5]
	
	-- Global Variables 
    local inputFolder = ""
    local outputFolder = ""
    local startPattern = #("\"unknown5\": \"00004040\",", "\"entry\": [")
    local endPattern   = #("}", "]", "}")
    local startTime = 0

    -- ETA/Progress state
    local fileWeights = #()      -- per-file byte weights (input+output)
    local totalBytes  = 0        -- sum of all weights
    local processedBytes = 0     -- bytes processed so far
    local emaSecPerByte = undefined  -- exponential moving average of seconds/byte
    local lastFileStartTS = 0    -- per-file start timestamp
    
    -- Helper function to format time in seconds to HH:MM:SS
    fn formatTime seconds = (
        local s = amax 0 seconds
        local hours = (s / 3600) as integer
        local mins = ((s - (hours * 3600)) / 60) as integer
        local secs = (s - (hours * 3600) - (mins * 60)) as integer
        (formattedPrint hours format:"02d") + ":" + (formattedPrint mins format:"02d") + ":" + (formattedPrint secs format:"02d")
    )
    
    fn appendLog msg = ( dnLog.AppendText(msg); dnLog.ScrollToCaret() )
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
    
    fn updateButtonState = ( btnStart.enabled = (inputFolder != "" and outputFolder != "") )
    
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
        (lines.count + 1) -- fallback: append at end
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
    
    fn processFiles inputPath outputPath = (
        local jsonFiles = getAllJsonFiles inputPath
        local processedCount = 0
        local skippedCount = 0
        local errorCount = 0
        local totalFiles = jsonFiles.count
        
        -- Initialize progress and timing
        prgProgress.value = 0
        lblRemaining.caption = "Remaining: Calculating..."
        lblTimeTaken.caption = "Time taken: --:--:--"
        startTime = timeStamp()

        -- Pre-scan: compute byte weights (input + matching output size) for smoother ETA
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
        
        appendLog ("Scanning folder: " + inputPath + "\r\n")
        appendLog ("Found " + totalFiles as string + " JSON files\r\n")
        appendLog ("------------------------------------------------\r\n")
        
        for i = 1 to totalFiles do (
            local f = jsonFiles[i]
            local filename = filenameFromPath f

            -- per-file stopwatch
            lastFileStartTS = timeStamp()

            -- progress before processing current file (bytes from previous files)
            if totalBytes > 0 do prgProgress.value = ((processedBytes as float) / totalBytes * 100.0)
            
            windows.processPostedMessages()
            
            local outFile = findMatchingOutputFile f inputPath outputPath
            if outFile == undefined do (
                appendLog ("ERROR: Output file missing for [" + filename + "]\r\n")
                errorCount += 1
                continue
            )
            
            -- Read input file
            local inFile = openFile f mode:"rt"
            if inFile == undefined do (
                appendLog ("ERROR: Could not read [" + filename + "]\r\n")
                errorCount += 1
                continue
            )
            local inputLines = #()
            while not eof inFile do append inputLines (readLine inFile)
            close inFile
            
            -- Extract block from INPUT
            local blockLines = extractBlock inputLines startPattern endPattern
            if blockLines.count == 0 do (
                appendLog ("SKIPPED: [" + filename + "] (pattern not found in input)\r\n")
                skippedCount += 1
                -- Even when skipped, advance ETA by the weight of this "processed" item to keep progress/ETA stable
                processedBytes += fileWeights[i]
                if totalBytes > 0 and emaSecPerByte != undefined do (
                    local remainingBytes = max2 0 (totalBytes - processedBytes)
                    local remainingSec = remainingBytes * emaSecPerByte
                    lblRemaining.caption = "Remaining: " + (formatTime remainingSec)
                    prgProgress.value = ((processedBytes as float) / totalBytes * 100.0)
                )
                continue
            )
            
            -- Read output file
            local outFileHandle = openFile outFile mode:"rt"
            if outFileHandle == undefined do (
                appendLog ("ERROR: Could not read output [" + filename + "]\r\n")
                errorCount += 1
                -- also advance ETA to avoid stall
                processedBytes += fileWeights[i]
                continue
            )
            local outputLines = #()
            while not eof outFileHandle do append outputLines (readLine outFileHandle)
            close outFileHandle
            
            -- Try to find the block in OUTPUT (full)
            local outStartIdxFull = findPatternInLines outputLines startPattern
            local outEndIdxFull   = findPatternInLines outputLines endPattern

            -- Also detect partial starts:
            local idxUnknown5     = findLineEq outputLines "\"unknown5\": \"00004040\","
            local idxEntryEmpty1  = findLineEq outputLines "\"entry\": []"
            local idxEntryEmpty2  = findLineEq outputLines "\"entry\":[]"
            local idxEntryEmpty   = (if idxEntryEmpty1 != 0 then idxEntryEmpty1 else idxEntryEmpty2)

            -- Backup before modifying
            if chkBackup.checked do (
                local backupFile = outFile + ".bak"
                if not copyFile outFile backupFile do appendLog ("WARNING: Backup failed for [" + filename + "]\r\n")
            )

            local newContent = #()
            if (outStartIdxFull != 0 and outEndIdxFull != 0) then (
                -- Case 1: REPLACE existing full block
                for j = 1 to (outStartIdxFull - 1) do append newContent outputLines[j]
                join newContent blockLines
                for j = (outEndIdxFull + endPattern.count) to outputLines.count do append newContent outputLines[j]
                appendLog ("PROCESSED (replaced): [" + filename + "]\r\n")

            ) else if (idxUnknown5 != 0 or idxEntryEmpty != 0) then (
                -- Case 2: PARTIAL present -> OVERWRITE from earliest start to just AFTER root "}"
                local startIdx = if (idxUnknown5 != 0 and idxEntryEmpty != 0) then
                    (if idxUnknown5 < idxEntryEmpty then idxUnknown5 else idxEntryEmpty)
                else
                    (if idxUnknown5 != 0 then idxUnknown5 else idxEntryEmpty)

                local rootIdx = findInsertionIndex outputLines
                ensureCommaBefore outputLines startIdx

                for j = 1 to (startIdx - 1) do append newContent outputLines[j]
                join newContent blockLines
                -- IMPORTANT: skip the original root "}" (start from rootIdx+1)
                for j = (rootIdx + 1) to outputLines.count do append newContent outputLines[j]

                appendLog ("PROCESSED (fixed partial -> overwrite): [" + filename + "]\r\n")

            ) else (
                -- Case 3: Not found at all -> INSERT before root, and SKIP the original root "}"
                local insertionIdx = findInsertionIndex outputLines
                ensureCommaBefore outputLines insertionIdx

                for j = 1 to (insertionIdx - 1) do append newContent outputLines[j]
                join newContent blockLines
                -- IMPORTANT: skip the original root "}" (start from insertionIdx+1)
                for j = (insertionIdx + 1) to outputLines.count do append newContent outputLines[j]

                appendLog ("PROCESSED (inserted missing block): [" + filename + "]\r\n")
            )

            -- Final safety: remove duplicate trailing root brace if present
            newContent = dedupeTrailingRootBrace newContent
            
            -- Write output file
            local outFileHandle = createFile outFile
            if outFileHandle == undefined do (
                appendLog ("ERROR: Could not write [" + filename + "]\r\n")
                errorCount += 1
                -- still advance ETA so UI progresses
                processedBytes += fileWeights[i]
                continue
            )
            
            for line in newContent do format "%\r\n" line to:outFileHandle
            flush outFileHandle
            close outFileHandle

            -- === ETA update (size-weighted with EMA smoothing) ===
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
        
        -- Totals
        local totalTime = (timeStamp() - startTime) / 1000.0
        lblTimeTaken.caption = "Time taken: " + (formatTime totalTime)
        if processedBytes >= totalBytes and totalBytes > 0 do lblRemaining.caption = "Remaining: 00:00:00"
        
        appendLog ("------------------------------------------------\r\n")
        appendLog ("Processed: " + processedCount as string + " files\r\n")
        appendLog ("Skipped: " + skippedCount as string + " files\r\n")
        appendLog ("Errors: " + errorCount as string + " files\r\n")
        appendLog ("Transfer complete in " + (formatTime totalTime) + "!\r\n")
    )
    
    on JSONBlockReplacer open do (
        dnLog.Multiline = true
        dnLog.ReadOnly = true
        dnLog.WordWrap = false
        dnLog.ScrollBars = (dotNetClass "System.Windows.Forms.ScrollBars").Both
        dnLog.Font = dotNetObject "System.Drawing.Font" "Consolas" 10
        dnLog.BackColor = (dotNetClass "System.Drawing.Color").FromArgb 10 10 10
		dnLog.ForeColor = (dotNetClass "System.Drawing.Color").FromArgb 235 235 235
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
        dnLog.Text = "Starting transfer process...\r\n"
        appendLog ("Input: " + inputFolder + "\r\n")
        appendLog ("Output: " + outputFolder + "\r\n\r\n")
        processFiles inputFolder outputFolder
    )
)

createDialog JSONBlockReplacer
