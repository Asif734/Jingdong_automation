import CryptoKit
import Foundation

struct EnvironmentFingerprint: Codable, Equatable, Sendable {
    let macOSBuild: String
    let architecture: String
    let qianniuVersion: String
    let qianniuBuild: String
    let qianniuRuntimeArchitecture: String
    let displayScales: [Double]
    let structureDigest: String
    let semanticStructureDigest: String
    let digest: String

    static func make(from snapshot: CalibrationSnapshot) -> EnvironmentFingerprint {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let normalizedDisplays = snapshot.displays.sorted {
            if $0.relativeFrame.minX != $1.relativeFrame.minX {
                return $0.relativeFrame.minX < $1.relativeFrame.minX
            }
            return $0.relativeFrame.minY < $1.relativeFrame.minY
        }
        let normalizedWindows = snapshot.windows.sorted {
            if $0.roleCategory != $1.roleCategory { return $0.roleCategory < $1.roleCategory }
            if $0.relativeFrame.minX != $1.relativeFrame.minX {
                return $0.relativeFrame.minX < $1.relativeFrame.minX
            }
            return $0.relativeFrame.minY < $1.relativeFrame.minY
        }
        let normalizedNodeSources = snapshot.nodes.sorted { lhs, rhs in
            if lhs.relativeFrame.minY != rhs.relativeFrame.minY {
                return lhs.relativeFrame.minY < rhs.relativeFrame.minY
            }
            if lhs.relativeFrame.minX != rhs.relativeFrame.minX {
                return lhs.relativeFrame.minX < rhs.relativeFrame.minX
            }
            if lhs.role != rhs.role { return lhs.role < rhs.role }
            if lhs.labelCategory != rhs.labelCategory { return lhs.labelCategory < rhs.labelCategory }
            return lhs.id < rhs.id
        }
        let normalizedNodeIndices = Dictionary(
            uniqueKeysWithValues: normalizedNodeSources.enumerated().map { ($0.element.id, $0.offset) }
        )
        let normalizedNodes = normalizedNodeSources.map { node in
            StructuralNode(
                parentIndex: node.parentID.flatMap { normalizedNodeIndices[$0] },
                role: node.role,
                actionNames: node.actionNames.sorted(),
                labelCategory: node.labelCategory,
                relativeFrame: node.relativeFrame,
                hasValue: node.hasValue
            )
        }
        let structure = StructuralEnvelope(
            displays: normalizedDisplays.map {
                StructuralDisplay(relativeFrame: $0.relativeFrame, scale: $0.scale)
            },
            windows: normalizedWindows.map {
                StructuralWindow(
                    roleCategory: $0.roleCategory,
                    relativeFrame: $0.relativeFrame,
                    captureFrame: $0.captureFrame,
                    minimized: $0.minimized,
                    focused: $0.focused,
                    regionCategories: $0.regionCategories.sorted()
                )
            },
            nodes: normalizedNodes
        )
        let structureDigest = sha256((try? encoder.encode(structure)) ?? Data())
        let semanticStructure = normalizedNodes.map {
            SemanticNode(
                parentIndex: $0.parentIndex,
                role: $0.role,
                actionNames: $0.actionNames,
                labelCategory: $0.labelCategory,
                hasValue: $0.hasValue
            )
        }
        let semanticStructureDigest = sha256((try? encoder.encode(semanticStructure)) ?? Data())
        let environment = EnvironmentEnvelope(
            macOSBuild: snapshot.macOSBuild,
            architecture: snapshot.architecture,
            qianniuVersion: snapshot.qianniuVersion,
            qianniuBuild: snapshot.qianniuBuild,
            qianniuRuntimeArchitecture: snapshot.qianniuRuntimeArchitecture,
            displayScales: normalizedDisplays.map(\.scale),
            structureDigest: structureDigest
        )
        let digest = sha256((try? encoder.encode(environment)) ?? Data())
        return EnvironmentFingerprint(
            macOSBuild: snapshot.macOSBuild,
            architecture: snapshot.architecture,
            qianniuVersion: snapshot.qianniuVersion,
            qianniuBuild: snapshot.qianniuBuild,
            qianniuRuntimeArchitecture: snapshot.qianniuRuntimeArchitecture,
            displayScales: normalizedDisplays.map(\.scale),
            structureDigest: structureDigest,
            semanticStructureDigest: semanticStructureDigest,
            digest: digest
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct StructuralEnvelope: Codable {
    let displays: [StructuralDisplay]
    let windows: [StructuralWindow]
    let nodes: [StructuralNode]
}

private struct StructuralDisplay: Codable {
    let relativeFrame: CGRect
    let scale: Double
}

private struct StructuralWindow: Codable {
    let roleCategory: String
    let relativeFrame: CGRect
    let captureFrame: CGRect
    let minimized: Bool
    let focused: Bool
    let regionCategories: [String]
}

private struct StructuralNode: Codable {
    let parentIndex: Int?
    let role: String
    let actionNames: [String]
    let labelCategory: String
    let relativeFrame: CGRect
    let hasValue: Bool
}

private struct SemanticNode: Codable {
    let parentIndex: Int?
    let role: String
    let actionNames: [String]
    let labelCategory: String
    let hasValue: Bool
}

private struct EnvironmentEnvelope: Codable {
    let macOSBuild: String
    let architecture: String
    let qianniuVersion: String
    let qianniuBuild: String
    let qianniuRuntimeArchitecture: String
    let displayScales: [Double]
    let structureDigest: String
}
