[CmdletBinding()]
param(
    [string]$OutputPath = '.cloudflare-pages',
    [string]$GoogleVerificationToken = 'QEuTHVv3z9u0NQpWupeKsU1n8iw7v7qMQCblnyVXdnw'
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$outputRoot = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    [System.IO.Path]::GetFullPath($OutputPath)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputPath))
}
$originBase = 'https://sythos.github.io'
$cloudflareBase = 'https://sythos.pages.dev'
$sitemapNamespace = 'http://www.sitemaps.org/schemas/sitemap/0.9'

if ([string]::IsNullOrWhiteSpace($GoogleVerificationToken)) {
    throw 'Google verification token must not be empty.'
}

if (Test-Path -LiteralPath $outputRoot) {
    Remove-Item -LiteralPath $outputRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

# Copy only publishable repository content. Git metadata, workflow sources,
# and project notes stay out of the Pages artifact.
$excludedNames = @('.git', '.github', '.cloudflare-pages', '.gitignore', 'README.md')
Get-ChildItem -LiteralPath $repoRoot -Force |
    Where-Object { $_.Name -notin $excludedNames } |
    ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $outputRoot $_.Name) -Recurse -Force
    }

function Protect-OriginalPagesUrls([string]$Content, [System.Collections.Generic.List[string]]$ProtectedUrls) {
    $pattern = 'https://sythos\.github\.io/(?:JS_Barcode_Universal|GuloGulo)(?:/[^\s"''<>]*)?'
    return [System.Text.RegularExpressions.Regex]::Replace($Content, $pattern, {
        param($Match)
        $placeholder = "__SYTHOS_ORIGINAL_PAGES_$($ProtectedUrls.Count)__"
        $ProtectedUrls.Add($Match.Value)
        return $placeholder
    })
}

function Restore-OriginalPagesUrls([string]$Content, [System.Collections.Generic.List[string]]$ProtectedUrls) {
    for ($index = 0; $index -lt $ProtectedUrls.Count; $index++) {
        $placeholder = "__SYTHOS_ORIGINAL_PAGES_${index}__"
        $Content = $Content.Replace($placeholder, $ProtectedUrls[$index])
    }
    return $Content
}

function Rewrite-CloudflareHtml([string]$Content, [bool]$IsHomepage) {
    $protectedUrls = [System.Collections.Generic.List[string]]::new()
    $Content = Protect-OriginalPagesUrls $Content $protectedUrls
    $Content = $Content.Replace($originBase, $cloudflareBase)
    $Content = Restore-OriginalPagesUrls $Content $protectedUrls

    if ($IsHomepage) {
        $verificationLine = "    <meta name=`"google-site-verification`" content=`"$GoogleVerificationToken`" />"
        $verificationPattern = '(?m)^[ \t]*<meta name="google-site-verification"[^>]*>[ \t]*$'
        if ([System.Text.RegularExpressions.Regex]::IsMatch($Content, $verificationPattern)) {
            $Content = [System.Text.RegularExpressions.Regex]::Replace($Content, $verificationPattern, $verificationLine)
        } else {
            $robotsPattern = '(?m)^(    <meta name="robots" content="[^"]+">\r?\n)'
            if (-not [System.Text.RegularExpressions.Regex]::IsMatch($Content, $robotsPattern)) {
                throw 'Homepage is missing the robots meta tag required for verification insertion.'
            }
            $Content = [System.Text.RegularExpressions.Regex]::Replace($Content, $robotsPattern, "`$1$verificationLine`n", 1)
        }
    }

    return $Content
}

$htmlFiles = @(Get-ChildItem -LiteralPath $outputRoot -Filter '*.html' -File -Recurse)
foreach ($htmlFile in $htmlFiles) {
    $content = Get-Content -LiteralPath $htmlFile.FullName -Raw -Encoding UTF8
    $isHomepage = $htmlFile.FullName -eq (Join-Path $outputRoot 'index.html')
    $content = Rewrite-CloudflareHtml $content $isHomepage
    Set-Content -LiteralPath $htmlFile.FullName -Value $content -Encoding utf8
}

function Get-SitemapEntry([System.Xml.XmlElement]$UrlNode, [string]$Location) {
    [pscustomobject]@{
        Location = $Location
        LastModified = [string]$UrlNode.lastmod
        ChangeFrequency = [string]$UrlNode.changefreq
    }
}

function New-SitemapXml([object[]]$Entries) {
    $items = foreach ($entry in $Entries) {
        $location = [System.Security.SecurityElement]::Escape([string]$entry.Location)
        $lastModified = [System.Security.SecurityElement]::Escape([string]$entry.LastModified)
        $changeFrequency = [System.Security.SecurityElement]::Escape([string]$entry.ChangeFrequency)
        "  <url>`n    <loc>$location</loc>`n    <lastmod>$lastModified</lastmod>`n    <changefreq>$changeFrequency</changefreq>`n  </url>"
    }
    return @"
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="$sitemapNamespace">
$($items -join "`n")
</urlset>
"@
}

$sourceSitemapPath = Join-Path $outputRoot 'sitemap.xml'
[xml]$sourceSitemap = Get-Content -LiteralPath $sourceSitemapPath -Raw -Encoding UTF8
$namespace = [System.Xml.XmlNamespaceManager]::new($sourceSitemap.NameTable)
$namespace.AddNamespace('sm', $sitemapNamespace)
$localEntries = [System.Collections.Generic.List[object]]::new()
$githubEntries = [System.Collections.Generic.List[object]]::new()

foreach ($urlNode in @($sourceSitemap.SelectNodes('//sm:url', $namespace))) {
    $location = [string]$urlNode.loc
    if ($location -match '^https://sythos\.github\.io/(?:JS_Barcode_Universal|GuloGulo)/') {
        $githubEntries.Add((Get-SitemapEntry $urlNode $location))
    } elseif ($location -match '^https://sythos\.github\.io/') {
        $localEntries.Add((Get-SitemapEntry $urlNode ($location.Replace($originBase, $cloudflareBase))))
    } else {
        throw "Unexpected sitemap host: $location"
    }
}

if ($localEntries.Count -eq 0 -or $githubEntries.Count -eq 0) {
    throw "Expected both local and GitHub Pages sitemap entries; found local=$($localEntries.Count), github=$($githubEntries.Count)."
}

Set-Content -LiteralPath $sourceSitemapPath -Value (New-SitemapXml $localEntries) -Encoding utf8
Set-Content -LiteralPath (Join-Path $outputRoot 'sitemap-github.xml') -Value (New-SitemapXml $githubEntries) -Encoding utf8
Set-Content -LiteralPath (Join-Path $outputRoot 'sitemap.txt') -Value (New-SitemapXml $localEntries) -Encoding utf8

$robots = @"
User-agent: *
Allow: /

Sitemap: $cloudflareBase/sitemap.xml
Sitemap: $cloudflareBase/sitemap-github.xml
"@
Set-Content -LiteralPath (Join-Path $outputRoot 'robots.txt') -Value $robots -Encoding utf8

$llmsPath = Join-Path $outputRoot 'llms.txt'
$llms = Get-Content -LiteralPath $llmsPath -Raw -Encoding UTF8
$protectedLlmsUrls = [System.Collections.Generic.List[string]]::new()
$llms = Protect-OriginalPagesUrls $llms $protectedLlmsUrls
$llms = $llms.Replace($originBase, $cloudflareBase)
$llms = Restore-OriginalPagesUrls $llms $protectedLlmsUrls
$llms = $llms.Replace('# sythos.github.io', '# sythos.pages.dev')
$llms = $llms.Replace("Sythos's static, script-free portfolio", "Sythos's static, script-free Cloudflare Pages mirror")
Set-Content -LiteralPath $llmsPath -Value $llms -Encoding utf8

$homepagePath = Join-Path $outputRoot 'index.html'
$homepage = Get-Content -LiteralPath $homepagePath -Raw -Encoding UTF8
$expectedMeta = "<meta name=`"google-site-verification`" content=`"$GoogleVerificationToken`" />"
if (($homepage | Select-String -Pattern ([regex]::Escape($expectedMeta)) -AllMatches).Matches.Count -ne 1) {
    throw 'Cloudflare homepage must contain the Google verification meta tag exactly once.'
}
if ($homepage -match 'canonical" href="https://sythos\.github\.io/') {
    throw 'Cloudflare homepage still contains a GitHub canonical URL.'
}

Write-Output "Prepared Cloudflare Pages artifact: $outputRoot"
Write-Output "HTML files: $($htmlFiles.Count); local sitemap URLs: $($localEntries.Count); GitHub Pages URLs: $($githubEntries.Count)."
