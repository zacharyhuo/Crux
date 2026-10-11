import { deflateRawSync } from 'node:zlib';

export function candidateInfo(key, build = '2') {
  return { CFBundleIdentifier: 'com.zacharyhuo.Crux.Beta', CFBundleExecutable: 'Crux Beta', CFBundleVersion: build,
    CFBundleShortVersionString: '1.0', SUPublicEDKey: key, LSMinimumSystemVersion: '26.0',
    SUFeedURL: 'https://raw.githubusercontent.com/zacharyhuo/Crux/app-updates/beta/appcast.xml',
    SURequireSignedFeed: true, SUVerifyUpdateBeforeExtraction: true, SUEnableInstallerLauncherService: true };
}

export function plist(info) {
  const xml = value => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  return Buffer.from('<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>'
    + Object.entries(info).map(([key, value]) => `<key>${xml(key)}</key>` + (typeof value === 'boolean' ? `<${value}/>` : `<string>${xml(value)}</string>`)).join('') + '</dict></plist>');
}

export const zipInfo = info => zip([{ name: 'Crux Beta.app/Contents/Info.plist', data: plist(info) }]);

// Real ZIP layout with CRCs; fixtures contain only inert data and never app code.
export function zip(entries) {
  const locals = [], directory = [];
  let offset = 0;
  for (const { name: rawName, data: rawData = '', mode = 0o100644, method = 0, flags = 0, extra = Buffer.alloc(0) } of entries) {
    const name = Buffer.from(rawName), data = Buffer.from(rawData), packed = method === 8 ? deflateRawSync(data) : data;
    let crc = 0xffffffff;
    for (const byte of data) { crc ^= byte; for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0); }
    crc = (crc ^ 0xffffffff) >>> 0;
    const local = Buffer.alloc(30), central = Buffer.alloc(46);
    local.writeUInt32LE(0x04034b50); local.writeUInt16LE(20, 4); local.writeUInt16LE(flags, 6); local.writeUInt16LE(method, 8);
    local.writeUInt32LE(crc, 14); local.writeUInt32LE(packed.length, 18); local.writeUInt32LE(data.length, 22); local.writeUInt16LE(name.length, 26);
    local.writeUInt16LE(extra.length, 28);
    central.writeUInt32LE(0x02014b50); central.writeUInt16LE(0x0314, 4); central.writeUInt16LE(20, 6); central.writeUInt16LE(flags, 8); central.writeUInt16LE(method, 10);
    central.writeUInt32LE(crc, 16); central.writeUInt32LE(packed.length, 20); central.writeUInt32LE(data.length, 24); central.writeUInt16LE(name.length, 28);
    central.writeUInt16LE(extra.length, 30);
    central.writeUInt32LE((mode << 16) >>> 0, 38); central.writeUInt32LE(offset, 42);
    const descriptor = Buffer.alloc(flags & 8 ? 16 : 0);
    if (flags & 8) {
      local.fill(0, 14, 26);
      descriptor.writeUInt32LE(0x08074b50); descriptor.writeUInt32LE(crc, 4); descriptor.writeUInt32LE(packed.length, 8); descriptor.writeUInt32LE(data.length, 12);
    }
    locals.push(local, name, extra, packed, descriptor); directory.push(central, name, extra);
    offset += local.length + name.length + extra.length + packed.length + descriptor.length;
  }
  const central = Buffer.concat(directory), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(central.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, central, end]);
}
