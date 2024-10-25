function Resolve-LiteralPathAsFullPath {
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory, ValueFromPipeline, Position = 0)] [string] $Path)

    begin {
        $isWinOS = [System.Environment]::OSVersion.Platform -in 'Win32NT'
        Set-Variable -Option Constant -Name isWindows -Value $isWinOS -ErrorAction SilentlyContinue
        $rootPathPattrn = if ($isWindows) { '^\S+\:\\' } else { '^/|(?:\S+\:/)' }
        [string[]] $resultPaths = @()
    }
    
    process {
        try { $fullProviderPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
        catch { throw } if (-not $?) { return } # If error then go next pipeline item, no matter what ErrorAction is.

        if ($fullProviderPath -notmatch $rootPathPattrn) {
            $toReplace = '^' + [regex]::Escape($PWD.Drive.Root).TrimEnd('\', '/') + '($|[\\/])'
            $replaceBy = ($PWD.Path | Select-String -Pattern $rootPathPattrn).Matches.Value
            $fullPowerShellPath = $fullProviderPath -replace $toReplace, $replaceBy
            $resultPaths += @($fullPowerShellPath)
        }
        else {
            $resultPaths += @($fullProviderPath)
        }
    }

    end {
        $resultPaths = $resultPaths | Where-Object { $_ }
        return $resultPaths
    }
}

function Use-WildcardEscaping {
    [CmdletBinding()]
    [OutputType([string])]
    Param ([Parameter(Mandatory, ValueFromPipeline, Position = 0)] [string] $Literal)

    begin { [string[]] $resultPatterns = @() }

    process {
        [string] $wildcardPattern = $null
        $wildcardPattern = $Literal -replace '[`\*\?\[\]]', '`$0'
        $resultPatterns += @($wildcardPattern)
    }

    end {
        $resultPatterns = $resultPatterns | Where-Object { $_ }
        return $resultPatterns
    }
}

function Resolve-WildcardPathAsFullPath {
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory, ValueFromPipeline, Position = 0)] [string] $Path)

    begin { [string[]] $resultPaths = @() }

    process {
        # Remove Unnecessary Escape Characters
        $Path = @($Path | Select-String -Pattern '`?.' -AllMatches  |
            ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } |
            ForEach-Object { $_ -replace '`([^`\*\?\[\]])', '$1' }) -join ''

        if ($Path -match '^(\S+\:(?:[\\/])+)(.*)$' -or
            $Path -match '^([\\/])+(.*)$' -or
            $Path -match '^(\S+\:)((?![\\/]+).*)$') {
            $pathHead, $pathTail = $Matches[1..2]
        }
        elseif ($Path -match '^([^\\/]+(?:[\\/])*)(.*)$') {
            if (($Matches[1] -replace '`.') -notmatch '[\?\*\[\]]') {
                $pathHead, $pathTail = $Matches[1..2]
            }
            else {
                $pathHead, $pathTail = '.', $Path
            }
        }

        $literalPathHead = $pathHead -replace '`(.)', '$1'
        try { $fullLiteralPathHead = Resolve-LiteralPathAsFullPath $literalPathHead }
        catch { throw } if (-not $?) { return }
        $fullPath = [IO.Path]::Combine($(Use-WildcardEscaping $fullLiteralPathHead), $pathTail)
        try { $fullPath = Resolve-LiteralPathAsFullPath $fullPath }
        catch { throw } if (-not $?) { return }

        $resultPaths += @($fullPath)
    }

    end {
        $resultPaths = $resultPaths | Where-Object { $_ }
        return $resultPaths
    }
}

function Resolve-FullPath {
    [CmdletBinding(DefaultParameterSetName = 'LiteralPath')]
    [OutputType([string[]])]    
    param (
        [Parameter(Mandatory, ParameterSetName = 'LiteralPath', Position = 0, ValueFromPipeline)]
        [Alias('Path')]
        [string[]] $LiteralPath,

        [Parameter(Mandatory, ParameterSetName = 'WildcardPath', ValueFromPipeline)]
        [string[]] $WildcardPath
    )

    begin { [string[]] $resultPaths = @() }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'LiteralPath') {
            foreach ($path in @($LiteralPath | Where-Object { $_ })) {
                try { $fullPath = Resolve-LiteralPathAsFullPath $path }
                catch { throw } if (-not $?) { return }
            }
        }
        else {
            foreach ($path in @($WildcardPath | Where-Object { $_ })) {
                try { $fullPath = Resolve-WildcardPathAsFullPath $path }
                catch { throw } if (-not $?) { return }
            }
        }

        $resultPaths += @($fullPath)
    }

    end {
        $resultPaths = $resultPaths | Where-Object { $_ }
        return $resultPaths
    }
}

function Use-WildcardToRegexConverter {
    [CmdletBinding()]
    [OutputType([string])]
    Param ([Parameter(Mandatory, ValueFromPipeline, Position = 0)] [string] $Pattern)

    begin { [string[]] $resultPatterns = @() }

    process {
        $regexPattern = @($Pattern | Select-String -Pattern '`?.' -AllMatches  |
            ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } |
            ForEach-Object {
                if ($_ -match '^[\[\]]') { $_ }
                elseif ($_ -eq '*') { '.*' }
                elseif ($_ -eq '?') { '.' }
                elseif ($_ -eq '`]') { '\]' }
                else { [regex]::Escape($($_ -replace '`(.)', '$1')) }
            }) -join ''

        $resultPatterns += @($regexPattern)
    }

    end {
        $resultPatterns = $resultPatterns | Where-Object { $_ } 
        return $resultPatterns
    }
}

function Use-WildcardPathFinding {
    [CmdletBinding()]
    [OutputType([string[]])]
    param (
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [string] $Path,
        [string] $StartIn
    )

    begin { [string[]] $resultPaths = @() }

    process {
        if ($Path -notmatch '^([\\/]*[^\\/]+[\\/]*)(.*)$') { return }
        $pathHead, $pathTail = $Matches[1..2]

        if (($pathHead -replace '`.') -notmatch '[\?\*\[\]]') {
            $foundLiteralPaths = @([IO.Path]::Combine($StartIn, ($pathHead -replace '`(.)', '$1')) |
                Where-Object { Test-Path -LiteralPath $_ } | Resolve-Path -LiteralPath { $_ })
        }
        else {
            $pathHeadRegexPattern = Use-WildcardToRegexConverter -Pattern $pathHead.TrimEnd('\', '/')

            try {
                $subItemPaths = Use-WildcardEscaping -Literal $StartIn | Join-Path -Path { $_ } *
                $subItemPathInfos = @(Resolve-Path -Path $subItemPaths)
            }
            catch { throw } if (-not $?) { return }

            $foundLiteralPaths = @($subItemPathInfos | ForEach-Object { $_.Path } |
                Where-Object { (Split-Path $_ -Leaf) -match $pathHeadRegexPattern })

            if ($pathHead -match '[\\/]$') {
                $foundLiteralPaths = @($foundLiteralPaths | Join-Path -Path { $_ } $null |
                    Where-Object { Test-Path -LiteralPath $_ } )
            }
        }

        if ([string]::IsNullOrEmpty($pathTail)) {
            $resultPaths += @($foundLiteralPaths)
            return
        }

        try {
            $foundLiteralPaths | ForEach-Object { Use-WildcardPathFinding -Path $pathTail -StartIn $_ }
        }
        catch { throw } if (-not $?) { return }
    }

    end {
        $resultPaths = $resultPaths | Where-Object { $_ }
        return $resultPaths
    }
}

function Resolve-LiteralPathAsAbsolutePath {
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory, ValueFromPipeline, Position = 0)] [string] $Path)

    begin { [string[]] $resultPaths = @() }

    process {
        try { $fullLiteralPath = $LiteralPath | Resolve-LiteralPathAsFullPath -Path { $_ } }
        catch { throw } if (-not $?) { return }
        if (-not (Test-Path -LiteralPath $fullLiteralPath)) {
            $resultPaths = $null
            throw "Cannot find path '$Path' because it does not exist."
        }
        $resultPaths += @($fullLiteralPath)
    }

    end {
        $resultPaths = $resultPaths | Where-Object { $_ } | Where-Object { Test-Path -LiteralPath $_ }
        return $resultPaths
    }
}

function Resolve-WildcardPathAsAbsolutePath {
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory, ValueFromPipeline, Position = 0)] [string] $Path)
    
    begin { [string[]] $resultPaths = @() }

    process {
        if (($Path -replace '`.') -match '[\?\*\[\]]') {
            try { $foundPaths = @(Resolve-WildcardPathAsFullPath -Path $Path | Use-WildcardPathFinding -Path { $_ }) }
            catch { throw } if (-not $?) { return }
        }
        else {
            $fullLiteralPath = $Path -replace '`(.)', '$1' | Resolve-FullPath -LiteralPath { $_ }
            if (-not (Test-Path -LiteralPath $fullLiteralPath)) {
                $resultPaths = $null
                throw "Cannot find path '$Path' because it does not exist."
            }
            $foundPaths = @($fullLiteralPath)
        }
        $resultPaths += @($foundPaths)
    }

    end {
        $resultPaths = $resultPaths | Where-Object { $_ } | Where-Object { Test-Path -LiteralPath $_ }
        return $resultPaths
    }
}

function Resolve-AbsolutePath {    
    [CmdletBinding(DefaultParameterSetName = 'LiteralPath')]
    [OutputType([string[]])]
    param (
        [Parameter(Mandatory, ParameterSetName = 'LiteralPath', Position = 0, ValueFromPipeline)]
        [Alias('Path')]
        [string[]] $LiteralPath,

        [Parameter(Mandatory, ParameterSetName = 'WildcardPath', ValueFromPipeline)]
        [string[]] $WildcardPath,

        [Parameter(ParameterSetName = 'LiteralPath')]
        [Parameter(ParameterSetName = 'WildcardPath')]
        [switch] $AsEscaped
    )

    begin { [string[]] $resultPaths = @() }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'LiteralPath') {
            $LiteralPath = @($LiteralPath | Where-Object { $_ })
            try { $absPaths = @($LiteralPath | Resolve-LiteralPathAsAbsolutePath -Path { $_ }) }
            catch { throw } if (-not $?) { return }
        }
        else {
            try { $absPaths = @($WildcardPath | Resolve-WildcardPathAsAbsolutePath -Path { $_ }) }
            catch { throw } if (-not $?) { return }
        }

        $resultPaths += @($absPaths)
    }

    end {
        $resultPaths = $resultPaths | Where-Object { $_ } | Where-Object { Test-Path -LiteralPath $_ }
        if ($AsEscaped) { $resultPaths = $resultPaths | Use-WildcardEscaping -Literal { $_ } }
        return $resultPaths
    }
}

function Resolve-FullPathAsRelativePath {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [string] $FullPath,
        [string] $BasePath = $PWD.Path
    )

    begin { [string[]] $resultPaths = @() }

    process {
        if ($FullPath.TrimEnd('\', '/') -notmatch '^([\\/]*[^\\/]+[\\/]+)(.*)$' ) { return }
        $fullPathParts = @($Matches[1]; ($Matches[2] -split '[\\/]+'))
        if ($BasePath.TrimEnd('\', '/') -notmatch '^([\\/]*[^\\/]+[\\/]+)(.*)$' ) { return }
        $basePathParts = @($Matches[1]; ($Matches[2] -split '[\\/]+'))

        $relativePathParts = $fullPathParts; $isForked = $false
        foreach ($i in 0 .. ($basePathParts.Count - 1)) {
            $isForked = $isForked -or $basePathParts[$i] -ne $fullPathParts[$i]
            if ($isForked) { $relativePathParts = @('..') + @($relativePathParts) }
            else { $relativePathParts = $relativePathParts | Select-Object -Skip 1 }
        }
        if (-not $isForked) { $relativePathParts = @('.') + @($relativePathParts) }

        $relativePath = ''
        $relativePathParts | ForEach-Object { $relativePath = [IO.Path]::Combine($relativePath, $_) }

        $resultPaths += @($relativePath)
    }

    end {
        $resultPaths = $resultPaths | Where-Object { $_ }
        return $resultPaths
    }
}

function Resolve-RelativePath {
    [CmdletBinding(DefaultParameterSetName = 'LiteralPath')]
    [OutputType([string[]])]    
    param (
        [Parameter(Mandatory, ParameterSetName = 'LiteralPath', Position = 0, ValueFromPipeline)]
        [Alias('Path')]
        [string[]] $LiteralPath,

        [Parameter(Mandatory, ParameterSetName = 'WildcardPath', ValueFromPipeline)]
        [string[]] $WildcardPath,

        [Parameter(ParameterSetName = 'WildcardPath', ValueFromPipeline)]
        [Parameter(ParameterSetName = 'LiteralPath', ValueFromPipeline)]
        [string] $BasePath = $PWD.Path
    )

    begin { [string[]] $resultPaths = @() }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'LiteralPath') {
            $LiteralPath = @($LiteralPath | Where-Object { $_ })
            try {
                $fullLiteralPaths = @($LiteralPath | Resolve-LiteralPathAsFullPath -Path { $_ })
                $fullLiteralBasePath = Resolve-LiteralPathAsFullPath -Path $BasePath
            }
            catch { throw } if (-not $?) { return }
            $relativePaths = @($fullLiteralPaths | Resolve-FullPathAsRelativePath -FullPath { $_ } -BasePath $fullLiteralBasePath)
        }
        else {
            try {
                $fullWildcardPath = @($WildcardPath | Resolve-WildcardPathAsFullPath -Path { $_ })
                $fullWildcardBasePath = Resolve-LiteralPathAsFullPath -Path $BasePath | Use-WildcardEscaping -Literal { $_ }
            }
            catch { throw } if (-not $?) { return }
            $relativePaths = @($fullWildcardPath | Resolve-FullPathAsRelativePath -FullPath { $_ } -BasePath $fullWildcardBasePath)
        }

        $resultPaths += @($relativePaths)
    }

    end {
        $resultPaths = $resultPaths | Where-Object { $_ }
        return $resultPaths
    }
}

Set-Alias -Name 'rvfpa' -Value 'Resolve-FullPath'
Set-Alias -Name 'rvapa' -Value 'Resolve-AbsolutePath'
Set-Alias -Name 'rvrpa' -Value 'Resolve-RelativePath'
