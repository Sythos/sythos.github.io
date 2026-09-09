import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const outputArgument = process.argv[2] || '.cloudflare-pages';
const outputRoot = path.resolve(repoRoot, outputArgument);
const originBase = 'https://sythos.github.io';
const cloudflareBase = 'https://sythos.pages.dev';
const sitemapNamespace = 'http://www.sitemaps.org/schemas/sitemap/0.9';
const googleVerificationToken = 'QEuTHVv3z9u0NQpWupeKsU1n8iw7v7qMQCblnyVXdnw';

function copyPublishableRoot() {
  const excludedNames = new Set([
    '.git',
    '.github',
    '.cloudflare-pages',
    '.gitignore',
    'README.md',
  ]);

  fs.mkdirSync(outputRoot, { recursive: true });
  for (const entry of fs.readdirSync(repoRoot, { withFileTypes: true })) {
    if (excludedNames.has(entry.name)) continue;
    fs.cpSync(
      path.join(repoRoot, entry.name),
      path.join(outputRoot, entry.name),
      { recursive: true, force: true },
    );
  }
}

function protectOriginalPagesUrls(content) {
  const protectedUrls = [];
  const pattern = /https:\/\/sythos\.github\.io\/(?:JS_Barcode_Universal|GuloGulo)(?:\/[^\s"'<>]*)?/g;
  const protectedContent = content.replace(pattern, (url) => {
    const placeholder = `__SYTHOS_ORIGINAL_PAGES_${protectedUrls.length}__`;
    protectedUrls.push(url);
    return placeholder;
  });
  return { content: protectedContent, protectedUrls };
}

function restoreOriginalPagesUrls(content, protectedUrls) {
  let restored = content;
  protectedUrls.forEach((url, index) => {
    restored = restored.replaceAll(`__SYTHOS_ORIGINAL_PAGES_${index}__`, url);
  });
  return restored;
}

function rewriteCloudflareHtml(content, isHomepage) {
  const protectedResult = protectOriginalPagesUrls(content);
  let rewritten = protectedResult.content.replaceAll(originBase, cloudflareBase);
  rewritten = restoreOriginalPagesUrls(rewritten, protectedResult.protectedUrls);

  if (isHomepage) {
    const verificationLine = `    <meta name="google-site-verification" content="${googleVerificationToken}" />`;
    const verificationPattern = /^[ \t]*<meta name="google-site-verification"[^>]*>[ \t]*$/m;
    if (verificationPattern.test(rewritten)) {
      rewritten = rewritten.replace(verificationPattern, verificationLine);
    } else {
      const robotsPattern = /^(    <meta name="robots" content="[^"]+">\r?\n)/m;
      if (!robotsPattern.test(rewritten)) {
        throw new Error('Homepage is missing the robots meta tag required for verification insertion.');
      }
      rewritten = rewritten.replace(robotsPattern, `$1${verificationLine}\n`);
    }
  }

  return rewritten;
}

function decodeXml(value) {
  return value
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');
}

function escapeXml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
}

function readSitemapEntries(sitemapXml) {
  const entries = [];
  const urlPattern = /<url\b[^>]*>([\s\S]*?)<\/url>/g;
  for (const match of sitemapXml.matchAll(urlPattern)) {
    const block = match[1];
    const readElement = (name) => {
      const element = block.match(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`));
      return element ? decodeXml(element[1].trim()) : '';
    };
    entries.push({
      location: readElement('loc'),
      lastModified: readElement('lastmod'),
      changeFrequency: readElement('changefreq'),
    });
  }
  return entries;
}

function newSitemapXml(entries) {
  const items = entries.map((entry) => [
    '  <url>',
    `    <loc>${escapeXml(entry.location)}</loc>`,
    `    <lastmod>${escapeXml(entry.lastModified)}</lastmod>`,
    `    <changefreq>${escapeXml(entry.changeFrequency)}</changefreq>`,
    '  </url>',
  ].join('\n'));
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    `<urlset xmlns="${sitemapNamespace}">`,
    items.join('\n'),
    '</urlset>',
    '',
  ].join('\n');
}

function listFiles(root, predicate, results = []) {
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const fullPath = path.join(root, entry.name);
    if (entry.isDirectory()) listFiles(fullPath, predicate, results);
    else if (predicate(fullPath)) results.push(fullPath);
  }
  return results;
}

if (!googleVerificationToken) throw new Error('Google verification token must not be empty.');
fs.rmSync(outputRoot, { recursive: true, force: true });
copyPublishableRoot();

const htmlFiles = listFiles(outputRoot, (filePath) => filePath.toLowerCase().endsWith('.html'));
for (const htmlFile of htmlFiles) {
  const relativePath = path.relative(outputRoot, htmlFile);
  const content = fs.readFileSync(htmlFile, 'utf8');
  const rewritten = rewriteCloudflareHtml(content, relativePath === 'index.html');
  fs.writeFileSync(htmlFile, rewritten, 'utf8');
}

const sourceSitemapPath = path.join(outputRoot, 'sitemap.xml');
const sourceEntries = readSitemapEntries(fs.readFileSync(sourceSitemapPath, 'utf8'));
const localEntries = [];
const githubEntries = [];
for (const entry of sourceEntries) {
  if (/^https:\/\/sythos\.github\.io\/(?:JS_Barcode_Universal|GuloGulo)\//.test(entry.location)) {
    githubEntries.push(entry);
  } else if (entry.location.startsWith(`${originBase}/`)) {
    localEntries.push({ ...entry, location: entry.location.replace(originBase, cloudflareBase) });
  } else {
    throw new Error(`Unexpected sitemap host: ${entry.location}`);
  }
}
if (localEntries.length === 0 || githubEntries.length === 0) {
  throw new Error(`Expected both local and GitHub Pages sitemap entries; found local=${localEntries.length}, github=${githubEntries.length}.`);
}

fs.writeFileSync(sourceSitemapPath, newSitemapXml(localEntries), 'utf8');
fs.writeFileSync(path.join(outputRoot, 'sitemap-github.xml'), newSitemapXml(githubEntries), 'utf8');
fs.writeFileSync(path.join(outputRoot, 'sitemap.txt'), newSitemapXml(localEntries), 'utf8');
fs.writeFileSync(path.join(outputRoot, 'robots.txt'), [
  'User-agent: *',
  'Allow: /',
  '',
  `Sitemap: ${cloudflareBase}/sitemap.xml`,
  `Sitemap: ${cloudflareBase}/sitemap-github.xml`,
  '',
].join('\n'), 'utf8');

const llmsPath = path.join(outputRoot, 'llms.txt');
const llmsProtected = protectOriginalPagesUrls(fs.readFileSync(llmsPath, 'utf8'));
let llms = llmsProtected.content.replaceAll(originBase, cloudflareBase);
llms = restoreOriginalPagesUrls(llms, llmsProtected.protectedUrls)
  .replaceAll('# sythos.github.io', '# sythos.pages.dev')
  .replaceAll("Sythos's static, script-free portfolio", "Sythos's static, script-free Cloudflare Pages mirror");
fs.writeFileSync(llmsPath, llms, 'utf8');

const homepage = fs.readFileSync(path.join(outputRoot, 'index.html'), 'utf8');
const expectedMeta = `<meta name="google-site-verification" content="${googleVerificationToken}" />`;
if ((homepage.match(new RegExp(expectedMeta.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g')) || []).length !== 1) {
  throw new Error('Cloudflare homepage must contain the Google verification meta tag exactly once.');
}
if (/canonical" href="https:\/\/sythos\.github\.io\//.test(homepage)) {
  throw new Error('Cloudflare homepage still contains a GitHub canonical URL.');
}

console.log(`Prepared Cloudflare Pages artifact: ${outputRoot}`);
console.log(`HTML files: ${htmlFiles.length}; local sitemap URLs: ${localEntries.length}; GitHub Pages URLs: ${githubEntries.length}.`);
