$hashes = [ordered]@{}

Set-Location $args[0]

Get-ChildItem -File -Recurse -Exclude dalamud.txt,*.zip,*.pdb,*.ipdb,hashes.json | Foreach-Object {
    if ($_.FullName -like (Join-Path (Get-Location) "cachedSigs\*")) {
        return
    }

	$key = ($_.FullName | Resolve-Path -Relative).TrimStart(".\\")
	$val = (Get-FileHash $_.FullName -Algorithm MD5).Hash
    $hashes.Add($key, $val)
}

$hashes | ConvertTo-Json | Out-File -FilePath "hashes.json"

Get-FileHash "hashes.json" -Algorithm MD5
