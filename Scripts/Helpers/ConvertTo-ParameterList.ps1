# Splits a list parameter given as comma-separated text into separate values.
# powershell.exe -File binds "-Undo A,B" to a [string[]] parameter as the single
# value "A,B" (comma array syntax only applies under -Command), and the launcher
# forwards arrays the same way, so list parameters have to accept both forms.
function ConvertTo-ParameterList {
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Value
    )

    foreach ($entry in @($Value)) {
        if ($null -eq $entry) { continue }
        foreach ($part in ($entry -split ',')) {
            $trimmed = $part.Trim()
            if ($trimmed) { $trimmed }
        }
    }
}
