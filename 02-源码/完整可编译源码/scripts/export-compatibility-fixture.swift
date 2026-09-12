#!/usr/bin/env swift
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("用法：export-compatibility-fixture.swift <脱敏诊断包目录> <fixture输出目录>\n".utf8))
    exit(64)
}

let source = URL(fileURLWithPath: arguments[1], isDirectory: true)
let destination = URL(fileURLWithPath: arguments[2], isDirectory: true)
let fileManager = FileManager.default
let snapshot = source.appendingPathComponent("redacted-snapshot.json")
let profile = source.appendingPathComponent("machine-profile.json")
guard fileManager.fileExists(atPath: snapshot.path), fileManager.fileExists(atPath: profile.path) else {
    FileHandle.standardError.write(Data("诊断包缺少 redacted-snapshot.json 或 machine-profile.json\n".utf8))
    exit(66)
}
try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
try? fileManager.removeItem(at: destination.appendingPathComponent("snapshot.json"))
try? fileManager.removeItem(at: destination.appendingPathComponent("expected-profile.json"))
try fileManager.copyItem(at: snapshot, to: destination.appendingPathComponent("snapshot.json"))
try fileManager.copyItem(at: profile, to: destination.appendingPathComponent("expected-profile.json"))
print(destination.path)
