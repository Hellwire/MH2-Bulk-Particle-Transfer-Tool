rollout JSONBlockReplacer "Particle Data Transfer Tool 1.0" width:850 height:650 (
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
    local endPattern = #("}", "]", "}")
    local startTime = 0
    
    -- Helper function to format time in seconds to HH:MM:SS
    fn formatTime seconds = (
        local hours = (seconds / 3600) as integer
        local mins = ((seconds - (hours * 3600)) / 60) as integer
        local secs = (seconds - (hours * 3600) - (mins * 60)) as integer
        
        return (formattedPrint hours format:"02d") + ":" + \
               (formattedPrint mins format:"02d") + ":" + \
               (formattedPrint secs format:"02d")
    )
    
    fn appendLog msg = (
        dnLog.AppendText(msg)
        dnLog.ScrollToCaret()
    )
	
    fn normalizePath path = (
        return trimRight (path as string) "\\" 
    )
    
    -- Recursive function to get all JSON files
    fn getAllJsonFiles rootDir = (
        local files = #()
        local dirFiles = getFiles (rootDir + "\\*.json")
        join files dirFiles
        local subDirs = getDirectories (rootDir + "\\*")
        for dir in subDirs do (
            join files (getAllJsonFiles dir)
        )
        return files
    )
    
    fn findPatternInLines lines patternArray = (
        for i = 1 to (lines.count - patternArray.count + 1) do (
            local match = true
            for p = 1 to patternArray.count while match do (
                -- Trim whitespace for flexible matching
                local line = trimLeft (trimRight lines[i + p - 1])
                if line != patternArray[p] do match = false
            )
            if match do return i
        )
        return 0
    )
    
    fn updateButtonState = (
        btnStart.enabled = (inputFolder != "" and outputFolder != "")
    )
    
    fn extractBlock lines startPattern endPattern = (
        local startIdx = findPatternInLines lines startPattern
        if startIdx == 0 do (
            format "Start pattern not found. Looking for: %\n" startPattern
            return #()
        )
        
        local endIdx = findPatternInLines lines endPattern
        if endIdx == 0 do (
            format "End pattern not found. Looking for: %\n" endPattern
            return #()
        )
        
        return for i = startIdx to (endIdx + endPattern.count - 1) collect lines[i]
    )
    
	fn unitePathFolders folders = (
        if folders.count == 0 do return ""
        local path = folders[1]
        for i = 2 to folders.count do path += "\\" + folders[i]
        return path
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
        return (unitePathFolders folders)
    )
    
    fn findMatchingOutputFile inputFile inputFolder outputFolder = (
        local inputName = filenameFromPath inputFile
        local inputRelPath = trimLeft (substituteString inputFile inputFolder "") "\\"
        local cleanRelPath = removeNumericPrefix inputRelPath
        
        local allOutputFiles = getAllJsonFiles outputFolder
        for f in allOutputFiles do (
            local outputRelPath = trimLeft (substituteString f outputFolder "") "\\"
            local cleanOutputPath = removeNumericPrefix outputRelPath
            if cleanOutputPath == cleanRelPath do return f
        )
        return undefined
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
        startTime = timeStamp()  -- Record start time in milliseconds
        
        appendLog ("Scanning folder: " + inputPath + "\r\n")
        appendLog ("Found " + totalFiles as string + " JSON files\r\n")
        appendLog ("------------------------------------------------\r\n")
        
        for i = 1 to totalFiles do (
            local f = jsonFiles[i]
            local filename = filenameFromPath f
            
            -- Update progress bar
            prgProgress.value = (i as float / totalFiles * 100)
            
            -- Update remaining time estimate
            if i > 1 do (
                local elapsed = (timeStamp() - startTime) / 1000.0  -- Convert to seconds
                local perFile = elapsed / i
                local remaining = (totalFiles - i) * perFile
                lblRemaining.caption = "Remaining: " + (formatTime remaining)
            )
            
            -- Process Windows messages to update UI
            windows.processPostedMessages()
            
            -- Find matching output file
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
            
            -- Extract block
            local blockLines = extractBlock inputLines startPattern endPattern
            if blockLines.count == 0 do (
                appendLog ("SKIPPED: [" + filename + "] (pattern not found)\r\n")
                skippedCount += 1
                continue
            )
            
            -- Read output file
            local outFileHandle = openFile outFile mode:"rt"
            if outFileHandle == undefined do (
                appendLog ("ERROR: Could not read output [" + filename + "]\r\n")
                errorCount += 1
                continue
            )
            
            local outputLines = #()
            while not eof outFileHandle do append outputLines (readLine outFileHandle)
            close outFileHandle
            
            -- Find and replace block
            local outStartIdx = findPatternInLines outputLines startPattern
            if outStartIdx == 0 do (
                appendLog ("ERROR: Start pattern not found in output [" + filename + "]\r\n")
                errorCount += 1
                continue
            )
            
            local outEndIdx = findPatternInLines outputLines endPattern
            if outEndIdx == 0 do (
                appendLog ("ERROR: End pattern not found in output [" + filename + "]\r\n")
                errorCount += 1
                continue
            )
            
            -- Create backup
            if chkBackup.checked do (
                local backupFile = outFile + ".bak"
                if not copyFile outFile backupFile do (
                    appendLog ("WARNING: Backup failed for [" + filename + "]\r\n")
                )
            )
            
            -- Build new content
            local newContent = #()
            for j = 1 to (outStartIdx - 1) do append newContent outputLines[j]
            join newContent blockLines
            for j = (outEndIdx + endPattern.count) to outputLines.count do append newContent outputLines[j]
            
            -- Write output file
            local outFileHandle = createFile outFile
            if outFileHandle == undefined do (
                appendLog ("ERROR: Could not write [" + filename + "]\r\n")
                errorCount += 1
                continue
            )
            
            for line in newContent do format "%\r\n" line to:outFileHandle
            flush outFileHandle
            close outFileHandle
            
            appendLog ("PROCESSED: [" + filename + "]\r\n")
            processedCount += 1
        )
        
        -- Calculate and display total time taken
        local totalTime = (timeStamp() - startTime) / 1000.0
        lblTimeTaken.caption = "Time taken: " + (formatTime totalTime)
        lblRemaining.caption = "Remaining: 00:00:00"
        
        appendLog ("------------------------------------------------\r\n")
        appendLog ("Processed: " + processedCount as string + " files\r\n")
        appendLog ("Skipped: " + skippedCount as string + " files\r\n")
        appendLog ("Errors: " + errorCount as string + " files\r\n")
        appendLog ("Transfer complete in " + (formatTime totalTime) + "!\r\n")
    )
    
    on JSONBlockReplacer open do (
        -- Configure .NET TextBox
        dnLog.Multiline = true
        dnLog.ReadOnly = true
        dnLog.WordWrap = false
        dnLog.ScrollBars = (dotNetClass "System.Windows.Forms.ScrollBars").Both
        dnLog.Font = dotNetObject "System.Drawing.Font" "Consolas" 10
        dnLog.BackColor = (dotNetClass "System.Drawing.Color").FromArgb 10 10 10
		dnLog.ForeColor = (dotNetClass "System.Drawing.Color").FromArgb 235 235 235  -- White
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
