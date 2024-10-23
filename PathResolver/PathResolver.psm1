function Resolve-LiteralPathAsFullPath {
    [OutputType([string])]
    param ([Parameter(Mandatory, ValueFromPipeline, Position = 0)] [string] $Path)

    begin {
        $isWinOS = [System.Environment]::OSVersion.Platform -in 'Win32NT'
        Set-Variable -Option Constant -Name isWindows -Value $isWinOS -ErrorAction SilentlyContinue      
        $rootPathPattrn = if ($isWindows) { '^\S+\:\\' } else { '^/|(?:\S+\:/)' }
    }

    process {
        try { $fullProviderPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
        catch { throw }

        if ($fullProviderPath -notmatch $rootPathPattrn) {
            $toReplace = '^' + [regex]::Escape($PWD.Drive.Root).TrimEnd('\', '/') + '($|[\\/])'
            $replaceBy = ($PWD.Path | Select-String -Pattern $rootPathPattrn).Matches.Value
            $fullPowerShellPath = $fullProviderPath -replace $toReplace, $replaceBy
        }
        else {
            $fullPowerShellPath = $fullProviderPath
        }

        return $fullPowerShellPath
    }
}

function Use-WildcardEscaping {
    [OutputType([string])]
    Param ([Parameter(Mandatory, ValueFromPipeline, Position = 0)] [string] $Literal)
    process {
        $wildcardPattern = $Literal -replace '[`\*\?\[\]]', '`$0' 
        return $wildcardPattern
    }
}

function Resolve-WildcardPathAsFullPath {
    [OutputType([string])]
    param ([Parameter(Mandatory, ValueFromPipeline, Position = 0)] [string] $Path)

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
        try { $fullLiteralPathHead = Resolve-LiteralPathAsFullPath $literalPathHead } catch { throw }
        $fullPath = [IO.Path]::Combine($(Use-WildcardEscaping $fullLiteralPathHead), $pathTail)
        try { $fullPath = Resolve-LiteralPathAsFullPath $fullPath } catch { throw }

        return $fullPath
    }
}

function Resolve-FullPath {
    [OutputType([string[]])]
    [CmdletBinding(DefaultParameterSetName = 'LiteralPath')]
    param (
        [Parameter(Mandatory, ParameterSetName = 'LiteralPath', Position = 0, ValueFromPipeline)]
        [Alias('Path')]
        [string[]] $LiteralPath,

        [Parameter(Mandatory, ParameterSetName = 'WildcardPath', ValueFromPipeline)]
        [string[]] $WildcardPath
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq 'LiteralPath') {
            $LiteralPath = @($LiteralPath | Where-Object { $_ })
            try { $resultPaths = @($LiteralPath | Resolve-LiteralPathAsFullPath -Path { $_ }) }
            catch { throw }
        }
        else {
            try { $resultPaths = @($WildcardPath | Resolve-WildcardPathAsFullPath -Path { $_ }) }
            catch { throw }
        }

        return $resultPaths
    }
}

function Use-WildcardToRegexConverter {
    [OutputType([string])]
    Param ([Parameter(Mandatory, ValueFromPipeline, Position = 0)] [string] $Pattern)

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

        return $regexPattern
    }
}

function Use-WildcardPathFinding {
    [OutputType([string[]])]
    param (
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [string] $Path,
        [string] $StartIn
    )

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
        catch { throw }

        $foundLiteralPaths = @($subItemPathInfos | ForEach-Object { $_.Path } |
            Where-Object { (Split-Path $_ -Leaf) -match $pathHeadRegexPattern })

        if ($pathHead -match '[\\/]$') {
            $foundLiteralPaths = @($foundLiteralPaths | Join-Path -Path { $_ } $null |
                Where-Object { Test-Path -LiteralPath $_ } )
        }
    }

    if ([string]::IsNullOrEmpty($pathTail)) { return $foundLiteralPaths }

    try {
        $foundLiteralPaths | ForEach-Object { Use-WildcardPathFinding -Path $pathTail -StartIn $_ }
    }
    catch { throw }
}

function Resolve-WildcardPathAsAbsolutePath {
    [OutputType([string])]
    param ([Parameter(Mandatory, ValueFromPipeline, Position = 0)] [string] $Path)
    process {
        $resultPaths = @(Resolve-WildcardPathAsFullPath -Path $Path | Use-WildcardPathFinding -Path { $_ })
        return $resultPaths
    }    
}

function Resolve-AbsolutePath {
    [OutputType([string[]])]
    [CmdletBinding(DefaultParameterSetName = 'LiteralPath')]
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

    process {
        if ($PSCmdlet.ParameterSetName -eq 'LiteralPath') {
            $LiteralPath = @($LiteralPath | Where-Object { $_ })
            try { $resultPaths = @($LiteralPath | Resolve-LiteralPathAsFullPath -Path { $_ }) }
            catch { throw }
        }
        else {
            try { $resultPaths = @($WildcardPath | Resolve-WildcardPathAsAbsolutePath -Path { $_ }) }
            catch { throw }
        }

        try { $resultPaths = $resultPaths | Resolve-Path -LiteralPath { $_ } | ForEach-Object { $_.Path } }
        catch { throw }

        if ($AsEscaped) { $resultPaths = $resultPaths | Use-WildcardEscaping -Literal { $_ } }
        return $resultPaths                
    }
}

function Resolve-FullPathAsRelativePath {
    [OutputType([string])]
    param (
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [string] $FullPath,
        [string] $BasePath = $PWD.Path
    )

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

        return $relativePath
    }
}

function Resolve-RelativePath {
    [OutputType([string[]])]
    [CmdletBinding(DefaultParameterSetName = 'LiteralPath')]
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

    process {        
        if ($PSCmdlet.ParameterSetName -eq 'LiteralPath') {
            $LiteralPath = @($LiteralPath | Where-Object { $_ })
            try {
                $fullLiteralPaths = @($LiteralPath | Resolve-LiteralPathAsFullPath -Path { $_ }) 
                $fullLiteralBasePath = Resolve-LiteralPathAsFullPath -Path $BasePath 
            }
            catch { throw }            
            $resultPaths = @($fullLiteralPaths | Resolve-FullPathAsRelativePath -FullPath { $_ } -BasePath $fullLiteralBasePath)
        }
        else {
            try {
                $fullWildcardPath = @($WildcardPath | Resolve-WildcardPathAsFullPath -Path { $_ }) 
                $fullWildcardBasePath = Resolve-LiteralPathAsFullPath -Path $BasePath | Use-WildcardEscaping -Literal { $_ } 
            }
            catch { throw }           
            $resultPaths = @($fullWildcardPath | Resolve-FullPathAsRelativePath -FullPath { $_ } -BasePath $fullWildcardBasePath)
        }

        return $resultPaths
    }
}

Set-Alias -Name 'rvfpa' -Value 'Resolve-FullPath'
Set-Alias -Name 'rvapa' -Value 'Resolve-AbsolutePath'
Set-Alias -Name 'rvrpa' -Value 'Resolve-RelativePath'