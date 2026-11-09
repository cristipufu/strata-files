import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Strata
@testable import StrataAI
@testable import StrataArchives
@testable import StrataModel
@testable import StrataPreviews
@testable import StrataSupport

struct FormatPreviewAndMetadataTests {
    // MARK: - GeoTrackMetadata & GeoTrackPreviewView

    @Test func gpxKmlAndGeoJSONExtractTrackNameDistanceElevationGainAndStartLocation() throws {
        let tree = try TestTree("route.gpx", "route.kml", "route.geojson")
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1">
          <trk>
            <name>Făgăraș Ridge Trail</name>
            <trkseg>
              <trkpt lat="45.5980" lon="24.6160"><ele>2040</ele></trkpt>
              <trkpt lat="45.6030" lon="24.6250"><ele>2280</ele></trkpt>
              <trkpt lat="45.6080" lon="24.6350"><ele>2544</ele></trkpt>
            </trkseg>
          </trk>
        </gpx>
        """
        try Data(gpx.utf8).write(to: tree.url("route.gpx"))

        let gpxTrack = try #require(GeoTrackMetadata.read(tree.url("route.gpx")))
        #expect(gpxTrack.name == "Făgăraș Ridge Trail")
        #expect(gpxTrack.points.count == 3)
        #expect((gpxTrack.distanceMeters ?? 0) > 1000)
        #expect(gpxTrack.elevationGainMeters == 504)
        #expect(gpxTrack.startLocation == MediaLocation(latitude: 45.5980, longitude: 24.6160))

        let kml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <Placemark>
              <name>Bucegi Traverse</name>
              <LineString>
                <coordinates>25.4500,45.4000,2000 25.4600,45.4100,2250</coordinates>
              </LineString>
            </Placemark>
          </Document>
        </kml>
        """
        try Data(kml.utf8).write(to: tree.url("route.kml"))
        let kmlDetails = try #require(GeoTrackMetadata.read(tree.url("route.kml")))
        #expect(kmlDetails.name == "Bucegi Traverse")
        #expect(kmlDetails.elevationGainMeters == 250)

        let geojson = """
        {
          "type": "FeatureCollection",
          "features": [{
            "type": "Feature",
            "properties": { "name": "City Loop" },
            "geometry": {
              "type": "LineString",
              "coordinates": [[23.5800, 46.7700, 340], [23.5900, 46.7800, 395]]
            }
          }]
        }
        """
        try Data(geojson.utf8).write(to: tree.url("route.geojson"))
        let geoDetails = try #require(GeoTrackMetadata.read(tree.url("route.geojson")))
        #expect(geoDetails.name == "City Loop")
        #expect(geoDetails.elevationGainMeters == 55)
    }

    // MARK: - MLHeaderMetadata (.safetensors, .gguf, .npy)

    @Test func safetensorsGgufAndNumpyHeadersParseSafelyWithoutReadingTensorBodies() async throws {
        let tree = try TestTree("model.safetensors", "model.gguf", "array.npy")

        // 1. SafeTensors
        let headerJSON = """
        {
          "__metadata__": { "model_name": "Qwen-2.5", "architecture": "qwen2" },
          "model.embed_tokens.weight": { "dtype": "BF16", "shape": [151936, 3584], "data_offsets": [0, 1089077248] },
          "model.norm.weight": { "dtype": "BF16", "shape": [3584], "data_offsets": [1089077248, 1089084416] }
        }
        """
        let headerBytes = Data(headerJSON.utf8)
        var stData = Data()
        var lenLE = UInt64(headerBytes.count).littleEndian
        withUnsafeBytes(of: &lenLE) { stData.append(contentsOf: $0) }
        stData.append(headerBytes)
        try stData.write(to: tree.url("model.safetensors"))

        let stDetails = try #require(MLHeaderMetadata.read(tree.url("model.safetensors")))
        #expect(stDetails.format == "SafeTensors")
        #expect(stDetails.modelName == "Qwen-2.5")
        #expect(stDetails.architecture == "qwen2")
        #expect(stDetails.precision == "BF16")
        #expect(stDetails.tensors.count == 2)
        #expect(stDetails.totalParameters == 544_542_208)

        let stTable = try await TableLoader.load(tree.url("model.safetensors"), kind: .mlHeader)
        #expect(stTable.data.rows.count == 2)

        // 2. NumPy .npy
        var npy = Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, 0x01, 0x00])
        let npyHeader = "{'descr': '<f4', 'fortran_order': False, 'shape': (4,), }\n"
        var npyLen = UInt16(npyHeader.utf8.count).littleEndian
        withUnsafeBytes(of: &npyLen) { npy.append(contentsOf: $0) }
        npy.append(Data(npyHeader.utf8))
        for value: Float in [1.5, -2.0, 3.25, 42.0] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { npy.append(contentsOf: $0) }
        }
        try npy.write(to: tree.url("array.npy"))

        let npyDetails = try #require(MLHeaderMetadata.read(tree.url("array.npy")))
        #expect(npyDetails.format == "NumPy")
        #expect(npyDetails.precision == "float32")
        #expect(npyDetails.shapeDescription == "4")
        #expect(npyDetails.sampleValues.count == 4)
    }

    // MARK: - ParquetMetadata

    @Test func parquetFooterExtractsSchemaRowCountAndCreatedBy() async throws {
        let tree = try TestTree("events.parquet")
        // Build a minimal valid Parquet v1 file with Compact Thrift FileMetaData footer:
        // field 1 (i32 version = 1), field 2 (list<SchemaElement>: root + 2 columns), field 3 (i64 num_rows = 1250), field 6 (string created_by = "DuckDB")
        var footer = Data()
        // field 1 (delta 1, i32 = 5): zigzag(1) = 2
        footer.append(contentsOf: [0x15, 0x02])
        // field 2 (delta 1, list = 9): count 3, elemType struct(12) -> 0x3C
        footer.append(contentsOf: [0x19, 0x3C])
        // SchemaElement 0 (root): field 4 (name = "schema"), field 5 (num_children = 2), stop(0)
        footer.append(contentsOf: [0x48, 0x06])
        footer.append(contentsOf: "schema".utf8)
        footer.append(contentsOf: [0x15, 0x04, 0x00])
        // SchemaElement 1 ("user_id", INT64 = 2, REQUIRED = 0): field 1 (type=2 -> zigzag 4), field 3 (delta 2, rep=0), field 4 (delta 1, name="user_id"), stop(0)
        footer.append(contentsOf: [0x15, 0x04, 0x25, 0x00, 0x18, 0x07])
        footer.append(contentsOf: "user_id".utf8)
        footer.append(0x00)
        // SchemaElement 2 ("email", BYTE_ARRAY = 6, OPTIONAL = 1, converted_type UTF8 = 0):
        // field 1 (type=6 -> zigzag 12), field 3 (delta 2, rep=1 -> zigzag 2), field 4 (delta 1, name="email"), field 6 (delta 2, converted=0), stop(0)
        footer.append(contentsOf: [0x15, 0x0C, 0x25, 0x02, 0x18, 0x05])
        footer.append(contentsOf: "email".utf8)
        footer.append(contentsOf: [0x25, 0x00, 0x00])
        // field 3 (delta 1, i64 = 6): num_rows = 1250 (zigzag = 2500 = 0x9C4 -> varint 0xC4, 0x13)
        footer.append(contentsOf: [0x16, 0xC4, 0x13])
        // field 4 (delta 1, list = 9): row_groups empty list of struct (0x0C)
        footer.append(contentsOf: [0x19, 0x0C])
        // field 6 (delta 2, binary = 8): created_by = "DuckDB"
        footer.append(contentsOf: [0x28, 0x06])
        footer.append(contentsOf: "DuckDB".utf8)
        // stop
        footer.append(0x00)

        var fileData = Data("PAR1".utf8)
        fileData.append(footer)
        var footerLen = UInt32(footer.count).littleEndian
        withUnsafeBytes(of: &footerLen) { fileData.append(contentsOf: $0) }
        fileData.append(contentsOf: "PAR1".utf8)
        try fileData.write(to: tree.url("events.parquet"))

        let schema = try #require(ParquetMetadata.read(tree.url("events.parquet")))
        #expect(schema.rowCount == 1250)
        #expect(schema.createdBy == "DuckDB")
        #expect(schema.columns.map(\.name) == ["user_id", "email"])
        #expect(schema.columns[0].physicalType == "INT64")
        #expect(schema.columns[1].logicalType == "UTF8")

        let tableDoc = try await TableLoader.load(tree.url("events.parquet"), kind: .parquet)
        #expect(tableDoc.data.rows.count == 2)
    }

    // MARK: - TableLoader (.srt, .vtt, .jsonl, .xcstrings, .har) & NotebookLoader (.ipynb)

    @Test func tableAndNotebookLoadersParseStructuredDeveloperAndMediaFormats() async throws {
        let tree = try TestTree("captions.srt", "events.jsonl", "Localizable.xcstrings", "trace.har", "demo.ipynb")

        let srt = """
        1
        00:00:01,000 --> 00:00:03,500
        <i>Welcome</i> to Strata!

        2
        00:00:04,000 --> 00:00:06,000
        Fast native previews.
        """
        try Data(srt.utf8).write(to: tree.url("captions.srt"))
        let srtDoc = try await TableLoader.load(tree.url("captions.srt"), kind: .subtitles)
        #expect(srtDoc.data.rows.count == 2)
        #expect(srtDoc.data.rows[0] == [.text("1"), .text("00:00:01,000"), .text("00:00:03,500"), .text("Welcome to Strata!")])

        let jsonl = """
        {"id": 1, "event": "open", "ms": 12}
        {"id": 2, "event": "search", "query": "invoice"}
        """
        try Data(jsonl.utf8).write(to: tree.url("events.jsonl"))
        let jsonlDoc = try await TableLoader.load(tree.url("events.jsonl"), kind: .jsonLines)
        #expect(jsonlDoc.data.columns.map(\.title) == ["event", "id", "ms", "query"])
        #expect(jsonlDoc.data.rows.count == 2)

        let xcstrings = """
        {
          "sourceLanguage": "en",
          "strings": {
            "Copy": {
              "comment": "Action menu",
              "localizations": {
                "de": { "stringUnit": { "state": "translated", "value": "Kopieren" } },
                "ro": { "stringUnit": { "state": "translated", "value": "Copiază" } }
              }
            }
          }
        }
        """
        try Data(xcstrings.utf8).write(to: tree.url("Localizable.xcstrings"))
        let xcDoc = try await TableLoader.load(tree.url("Localizable.xcstrings"), kind: .xcstrings)
        #expect(xcDoc.data.columns.map(\.title) == ["Key", "Comment", "en", "de", "ro"])
        #expect(xcDoc.data.rows.count == 1)

        let har = """
        {
          "log": {
            "entries": [{
              "time": 42.6,
              "request": { "method": "POST", "url": "https://api.strata.dev/v1/search" },
              "response": { "status": 200, "content": { "size": 2048, "mimeType": "application/json; charset=utf-8" } }
            }]
          }
        }
        """
        try Data(har.utf8).write(to: tree.url("trace.har"))
        let harDoc = try await TableLoader.load(tree.url("trace.har"), kind: .har)
        #expect(harDoc.data.rows.count == 1)
        #expect(harDoc.data.rows[0][0] == .text("POST"))
        #expect(harDoc.data.rows[0][2] == .text("api.strata.dev"))

        let ipynb = """
        {
          "metadata": { "kernelspec": { "display_name": "Python 3", "language": "python" } },
          "cells": [
            { "cell_type": "markdown", "source": ["# Revenue Forecast\\n", "Quarterly analysis."] },
            {
              "cell_type": "code",
              "execution_count": 1,
              "source": ["print(40 + 2)"],
              "outputs": [{ "output_type": "stream", "text": ["42\\n"] }]
            }
          ]
        }
        """
        try Data(ipynb.utf8).write(to: tree.url("demo.ipynb"))
        let nbDoc = try await NotebookLoader.load(tree.url("demo.ipynb"))
        #expect(nbDoc.storage.value.string.contains("Revenue Forecast"))
        #expect(nbDoc.storage.value.string.contains("42"))
        #expect(nbDoc.customSummary?.first == "Notebook")
    }

    // MARK: - Malformed & Corrupt Input Safety

    @Test func malformedAndCorruptInputsReturnNilOrThrowCleanlyWithoutCrashing() async throws {
        let files = ["bad.parquet", "bad.safetensors", "bad.gguf", "bad.npy", "bad.gpx", "bad.kml", "bad.geojson", "bad.cer", "bad.mobileprovision", "bad.ttf", "bad.woff"]
        let tree = try TestTree("bad.parquet", "bad.safetensors", "bad.gguf", "bad.npy", "bad.gpx", "bad.kml", "bad.geojson", "bad.cer", "bad.mobileprovision", "bad.ttf", "bad.woff", "overflow.har", "overflow.ipynb")
        let payloads: [Data] = [
            Data(),
            Data([0x00, 0xFF, 0x7F, 0x80]),
            Data("PAR1".utf8) + Data([0x00, 0x00, 0x00, 0x00]) + Data("PAR1".utf8),
            Data("PAR1".utf8) + Data([0xFF, 0xFF, 0xFF, 0x7F]) + Data("PAR1".utf8),
            Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]),
            Data("GGUF".utf8) + Data([0x03, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
            Data("GGUF".utf8) + Data([0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            Data([0x93]) + Data("NUMPY".utf8) + Data([0x01, 0x00, 0xFF, 0xFF]),
            Data([0x93]) + Data("NUMPY".utf8) + Data([0x02, 0x00, 0xFF, 0xFF, 0xFF, 0x7F]),
            Data(#"<!DOCTYPE gpx [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><gpx>&xxe;</gpx>"#.utf8),
            Data(#"<?xml version="1.0" encoding="UTF-7"?><gpx><trk><name>x</name><trkseg><trkpt lat="1" lon="2"/></trkseg></trk></gpx>"#.utf8),
            Data("wOFF".utf8) + Data([0x00, 0x01, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x01]),
            Data("ttcf".utf8) + Data([0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF]),
        ]
        // Every corrupt payload is tested against every file extension and its corresponding parser
        for payload in payloads {
            for file in files {
                let url = tree.url(file)
                try payload.write(to: url)
                #expect(ParquetMetadata.read(url) == nil)
                #expect(MLHeaderMetadata.read(url) == nil)
                #expect(GeoTrackMetadata.read(url) == nil)
                #expect(CertificateMetadata.read(url) == nil)
                #expect(FontMetadata.read(url).isEmpty)
            }
        }

        // SafeTensors with out-of-range float dimension (1e300) must not trap on Int conversion
        let badST = Data(#"{"w":{"dtype":"F16","shape":[1e300,64],"data_offsets":[0,128]}}"#.utf8)
        #expect(MLHeaderMetadata.parseSafeTensorsHeader(badST) == nil)

        // Provisioning profile with DOCTYPE internal subset or ENTITY before <plist> must be rejected by our guard,
        // even when no entity reference is used inside <plist> (so Core Foundation would otherwise accept it).
        let unusedEntityProfile = Data(#"<!DOCTYPE plist [<!ENTITY unused "secret">]><plist version="1.0"><dict><key>Name</key><string>Plain</string></dict></plist>"#.utf8)
        #expect(CertificateMetadata.read(unusedEntityProfile, fileExtension: "mobileprovision") == nil)

        let utf7Profile = Data(#"<?xml version="1.0" encoding="UTF-7"?><plist version="1.0"><dict><key>Name</key><string>Plain</string></dict></plist>"#.utf8)
        #expect(CertificateMetadata.read(utf7Profile, fileExtension: "mobileprovision") == nil)

        // HAR and Notebook with huge float values (1e300) must not trap when converting to Int/Int64
        let overflowHAR = Data(#"{"log":{"entries":[{"time":1e300,"request":{"method":"GET","url":"https://example.com"},"response":{"status":1e300,"bodySize":1e300}}]}}"#.utf8)
        try overflowHAR.write(to: tree.url("overflow.har"))
        let harDoc = try await TableLoader.load(tree.url("overflow.har"), kind: .har)
        #expect(harDoc.data.rows.count == 1)

        let overflowNB = Data(#"{"cells":[{"cell_type":"code","execution_count":1e300,"source":["x = 1"]}]}"#.utf8)
        try overflowNB.write(to: tree.url("overflow.ipynb"))
        let nbDoc = try await NotebookLoader.load(tree.url("overflow.ipynb"))
        #expect(nbDoc.storage.value.string.contains("In [ ]:"))
    }

    // MARK: - GGUF v2/v3 Large Tokenizer & v1 Rejection, NumPy v2/v3, Parquet Large Row Groups

    @Test func ggufLargeTokenizerArrayAndNumpyV2V3AndParquetManyColumnChunksParseCleanly() throws {
        // 1. GGUF v1 must be rejected (32-bit layout vs v2/v3 64-bit layout)
        var ggufV1 = Data("GGUF".utf8)
        func appendU32(_ v: UInt32, to d: inout Data) {
            var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        }
        func appendU64(_ v: UInt64, to d: inout Data) {
            var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        }
        func appendGGUFString(_ s: String, to d: inout Data) {
            let utf8 = Data(s.utf8)
            appendU64(UInt64(utf8.count), to: &d)
            d.append(utf8)
        }
        appendU32(1, to: &ggufV1)
        appendU64(1, to: &ggufV1)
        appendU64(0, to: &ggufV1)
        #expect(MLHeaderMetadata.parseGGUFHeader(ggufV1) == nil)

        // 2. GGUF v3 with a 130,000-element tokenizer string array + 130,000-element float32 score array + 2 tensors
        var ggufV3 = Data("GGUF".utf8)
        appendU32(3, to: &ggufV3) // version 3
        appendU64(2, to: &ggufV3) // 2 tensors
        appendU64(5, to: &ggufV3) // 5 KV pairs

        // KV 1: general.architecture = "llama"
        appendGGUFString("general.architecture", to: &ggufV3)
        appendU32(8, to: &ggufV3)
        appendGGUFString("llama", to: &ggufV3)

        // KV 2: general.name = "Llama-3-8B-Instruct"
        appendGGUFString("general.name", to: &ggufV3)
        appendU32(8, to: &ggufV3)
        appendGGUFString("Llama-3-8B-Instruct", to: &ggufV3)

        // KV 3: general.file_type = 15 (Q4_K_M)
        appendGGUFString("general.file_type", to: &ggufV3)
        appendU32(4, to: &ggufV3)
        appendU32(15, to: &ggufV3)

        // KV 4: tokenizer.ggml.scores = array of 130,000 float32s (skipped in O(1))
        let vocabCount = 130_000
        appendGGUFString("tokenizer.ggml.scores", to: &ggufV3)
        appendU32(9, to: &ggufV3) // array
        appendU32(6, to: &ggufV3) // float32
        appendU64(UInt64(vocabCount), to: &ggufV3)
        ggufV3.append(Data(count: vocabCount * 4))

        // KV 5: tokenizer.ggml.tokens = array of 130,000 strings ("a")
        appendGGUFString("tokenizer.ggml.tokens", to: &ggufV3)
        appendU32(9, to: &ggufV3) // array
        appendU32(8, to: &ggufV3) // string
        appendU64(UInt64(vocabCount), to: &ggufV3)
        var singleToken = Data()
        appendU64(1, to: &singleToken)
        singleToken.append(0x61)
        ggufV3.reserveCapacity(ggufV3.count + vocabCount * 9 + 256)
        for _ in 0..<vocabCount {
            ggufV3.append(singleToken)
        }

        // Tensor 1: tok_embeddings.weight [4096, 128256], FP16 (type 1)
        appendGGUFString("tok_embeddings.weight", to: &ggufV3)
        appendU32(2, to: &ggufV3)
        appendU64(4096, to: &ggufV3)
        appendU64(128_256, to: &ggufV3)
        appendU32(1, to: &ggufV3)
        appendU64(0, to: &ggufV3)

        // Tensor 2: output_norm.weight [4096], FP32 (type 0)
        appendGGUFString("output_norm.weight", to: &ggufV3)
        appendU32(1, to: &ggufV3)
        appendU64(4096, to: &ggufV3)
        appendU32(0, to: &ggufV3)
        appendU64(1_050_673_152, to: &ggufV3)

        let parsedGGUF = try #require(MLHeaderMetadata.parseGGUFHeader(ggufV3))
        #expect(parsedGGUF.modelName == "Llama-3-8B-Instruct")
        #expect(parsedGGUF.architecture == "llama")
        #expect(parsedGGUF.precision == "Q4_K_M")
        #expect(parsedGGUF.tensors.count == 2)
        #expect(parsedGGUF.tensors[0].name == "tok_embeddings.weight")
        #expect(parsedGGUF.totalParameters == 525_340_672)

        // 3. GGUF with truncated KV section must NOT parse garbage tensors from a mid-KV offset
        var truncatedKV = Data("GGUF".utf8)
        appendU32(3, to: &truncatedKV)
        appendU64(1, to: &truncatedKV) // claims 1 tensor
        appendU64(2, to: &truncatedKV) // claims 2 KVs, but 2nd KV is truncated
        appendGGUFString("general.name", to: &truncatedKV)
        appendU32(8, to: &truncatedKV)
        appendGGUFString("PartialModel", to: &truncatedKV)
        appendGGUFString("broken.key", to: &truncatedKV)
        // missing valType & value
        let partialSummary = try #require(MLHeaderMetadata.parseGGUFHeader(truncatedKV))
        #expect(partialSummary.modelName == "PartialModel")
        #expect(partialSummary.tensors.isEmpty)

        // 4. NumPy v2 and v3 (4-byte header length)
        for major: UInt8 in [2, 3] {
            var npy = Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, major, 0x00])
            let header = "{'descr': '<i8', 'fortran_order': False, 'shape': (2, 3), }\n"
            appendU32(UInt32(header.utf8.count), to: &npy)
            npy.append(Data(header.utf8))
            for v: Int64 in [10, 20, 30, 40, 50, 60] {
                appendU64(UInt64(bitPattern: v), to: &npy)
            }
            let summary = try #require(MLHeaderMetadata.parseNPYHeader(npy))
            #expect(summary.precision == "int64")
            #expect(summary.totalParameters == 6)
            #expect(summary.sampleValues.count == 6)
        }

        // 5. Parquet with 40 columns × 25 row groups (1,000 column chunks)
        var footer = Data()
        footer.append(contentsOf: [0x15, 0x02]) // field 1: version = 1
        // field 2: schema list of 41 SchemaElements (1 root + 40 leaf columns)
        footer.append(contentsOf: [0x19, 0xFC, 41])
        footer.append(contentsOf: [0x48, 0x04])
        footer.append(contentsOf: "root".utf8)
        footer.append(contentsOf: [0x15, 80, 0x00]) // num_children = 40 (zigzag 80)
        for col in 0..<40 {
            let name = "col_\(col)"
            footer.append(contentsOf: [0x15, 0x04, 0x25, 0x00, 0x18, UInt8(name.utf8.count)])
            footer.append(contentsOf: name.utf8)
            footer.append(0x00)
        }
        // field 3: num_rows = 5000 (zigzag 10000 = 0x90, 0x4E)
        footer.append(contentsOf: [0x16, 0x90, 0x4E])
        // field 4: row_groups list of 25 RowGroup structs, each with 40 ColumnChunk structs
        footer.append(contentsOf: [0x19, 0xFC, 25])
        for _ in 0..<25 {
            // RowGroup field 1: columns list of 40 structs
            footer.append(contentsOf: [0x19, 0xFC, 40])
            for _ in 0..<40 {
                // ColumnChunk with field 2 (file_offset = 0) and field 3 (meta_data struct with 5 i64 fields)
                footer.append(contentsOf: [0x26, 0x00, 0x1C, 0x15, 0x04, 0x56, 0x64, 0x16, 0xC8, 0x01, 0x00, 0x00])
            }
            footer.append(contentsOf: [0x16, 0x80, 0x08, 0x00]) // total_byte_size + stop
        }
        footer.append(0x00) // end of FileMetaData
        var parquetTail = footer
        appendU32(UInt32(footer.count), to: &parquetTail)
        parquetTail.append(contentsOf: "PAR1".utf8)
        let largeParquet = try #require(ParquetMetadata.readFooter(from: parquetTail))
        #expect(largeParquet.columns.count == 40)
        #expect(largeParquet.rowCount == 5000)
        #expect(largeParquet.rowGroupCount == 25)
    }

    // MARK: - Fonts (.ttf, .ttc, .woff), Certificates (.cer, .pem, .mobileprovision), and App Bundles (.app)

    @Test func fontCertificateProvisioningProfileAndAppBundleParsersAndFIFOProtection() throws {
        let tree = try TestTree("synthetic.ttf", "synthetic.ttc", "synthetic.woff", "cert.der", "cert.pem", "profile.mobileprovision")

        // 1. Build a minimal SFNT TrueType font with 'maxp' (512 glyphs) and 'name' tables
        func makeSFNT(family: String, style: String, fullName: String, postScript: String) -> Data {
            let nameRecords: [(nameID: UInt16, bytes: Data)] = [
                (0, Data("Copyright 2026 Strata".utf8)),
                (1, Data(family.utf8)),
                (2, Data(style.utf8)),
                (4, Data(fullName.utf8)),
                (5, Data("Version 2.1".utf8)),
                (6, Data(postScript.utf8)),
            ]
            var stringPool = Data()
            var recordHeaders = Data()
            func appendBE16(_ v: UInt16, to d: inout Data) {
                var be = v.bigEndian; withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
            }
            func appendBE32(_ v: UInt32, to d: inout Data) {
                var be = v.bigEndian; withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
            }
            for rec in nameRecords {
                appendBE16(1, to: &recordHeaders) // platformID = 1 (Mac Roman)
                appendBE16(0, to: &recordHeaders) // encodingID = 0
                appendBE16(0, to: &recordHeaders) // languageID = 0
                appendBE16(rec.nameID, to: &recordHeaders)
                appendBE16(UInt16(rec.bytes.count), to: &recordHeaders)
                appendBE16(UInt16(stringPool.count), to: &recordHeaders)
                stringPool.append(rec.bytes)
            }
            var nameTable = Data()
            appendBE16(0, to: &nameTable) // format 0
            appendBE16(UInt16(nameRecords.count), to: &nameTable)
            appendBE16(UInt16(6 + recordHeaders.count), to: &nameTable)
            nameTable.append(recordHeaders)
            nameTable.append(stringPool)

            var maxpTable = Data()
            appendBE32(0x0001_0000, to: &maxpTable) // version 1.0
            appendBE16(512, to: &maxpTable) // numGlyphs = 512

            var sfnt = Data()
            appendBE32(0x0001_0000, to: &sfnt) // TrueType sfntVersion
            appendBE16(2, to: &sfnt) // numTables = 2
            appendBE16(32, to: &sfnt)
            appendBE16(1, to: &sfnt)
            appendBE16(0, to: &sfnt)

            let maxpOffset = 12 + 2 * 16
            let nameOffset = maxpOffset + maxpTable.count
            sfnt.append(contentsOf: "maxp".utf8)
            appendBE32(0, to: &sfnt)
            appendBE32(UInt32(maxpOffset), to: &sfnt)
            appendBE32(UInt32(maxpTable.count), to: &sfnt)

            sfnt.append(contentsOf: "name".utf8)
            appendBE32(0, to: &sfnt)
            appendBE32(UInt32(nameOffset), to: &sfnt)
            appendBE32(UInt32(nameTable.count), to: &sfnt)

            sfnt.append(maxpTable)
            sfnt.append(nameTable)
            return sfnt
        }

        let sfnt1 = makeSFNT(family: "Strata Sans", style: "Regular", fullName: "Strata Sans Regular", postScript: "StrataSans-Regular")
        try sfnt1.write(to: tree.url("synthetic.ttf"))
        let ttfFaces = FontMetadata.read(tree.url("synthetic.ttf"))
        #expect(ttfFaces.count == 1)
        #expect(ttfFaces[0].family == "Strata Sans")
        #expect(ttfFaces[0].style == "Regular")
        #expect(ttfFaces[0].fullName == "Strata Sans Regular")
        #expect(ttfFaces[0].postScriptName == "StrataSans-Regular")
        #expect(ttfFaces[0].glyphCount == 512)
        #expect(ttfFaces[0].version == "2.1")

        // TTC wrapping two faces
        var ttc = Data("ttcf".utf8)
        func appendBE32(_ v: UInt32, to d: inout Data) {
            var be = v.bigEndian; withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
        }
        func appendBE16(_ v: UInt16, to d: inout Data) {
            var be = v.bigEndian; withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
        }
        appendBE32(0x0001_0000, to: &ttc)
        appendBE32(1, to: &ttc) // 1 font at offset 16
        appendBE32(16, to: &ttc)
        ttc.append(sfnt1.dropFirst(16)) // wait: TTC offset points to an SFNT header inside the file
        // Build a self-contained TTC where SFNT table offsets are relative to the start of the TTC file:
        var validTTC = Data("ttcf".utf8)
        appendBE32(0x0001_0000, to: &validTTC)
        appendBE32(1, to: &validTTC)
        let sfntStart = 16
        appendBE32(UInt32(sfntStart), to: &validTTC)
        var adjustedSFNT = sfnt1
        let oldMaxpOff = sfnt1.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 12 + 8, as: UInt32.self)) }
        let oldNameOff = sfnt1.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 12 + 16 + 8, as: UInt32.self)) }
        var newMaxpBE = (oldMaxpOff + UInt32(sfntStart)).bigEndian
        var newNameBE = (oldNameOff + UInt32(sfntStart)).bigEndian
        adjustedSFNT.replaceSubrange((12 + 8)..<(12 + 12), with: withUnsafeBytes(of: &newMaxpBE) { Data($0) })
        adjustedSFNT.replaceSubrange((12 + 16 + 8)..<(12 + 16 + 12), with: withUnsafeBytes(of: &newNameBE) { Data($0) })
        validTTC.append(adjustedSFNT)
        try validTTC.write(to: tree.url("synthetic.ttc"))
        let ttcFaces = FontMetadata.read(tree.url("synthetic.ttc"))
        #expect(ttcFaces.count == 1)
        #expect(ttcFaces[0].postScriptName == "StrataSans-Regular")

        // WOFF v1 wrapping uncompressed SFNT tables
        let maxpOffset = Int(oldMaxpOff)
        let nameOffset = Int(oldNameOff)
        let maxpBytes = sfnt1.subdata(in: maxpOffset..<nameOffset)
        let nameBytes = sfnt1.subdata(in: nameOffset..<sfnt1.count)
        var woff = Data("wOFF".utf8)
        appendBE32(0x0001_0000, to: &woff) // flavor
        let woffTableStart = 44 + 2 * 20
        let woffTotalLen = woffTableStart + maxpBytes.count + nameBytes.count
        appendBE32(UInt32(woffTotalLen), to: &woff)
        appendBE16(2, to: &woff) // numTables = 2
        appendBE16(0, to: &woff) // reserved
        appendBE32(UInt32(sfnt1.count), to: &woff)
        appendBE16(1, to: &woff) // majorVersion
        appendBE16(0, to: &woff) // minorVersion
        appendBE32(0, to: &woff) // metaOffset
        appendBE32(0, to: &woff) // metaLength
        appendBE32(0, to: &woff) // metaOrigLength
        appendBE32(0, to: &woff) // privOffset
        appendBE32(0, to: &woff) // privLength
        // WOFF TableDirectoryEntry 0: maxp
        woff.append(contentsOf: "maxp".utf8)
        appendBE32(UInt32(woffTableStart), to: &woff)
        appendBE32(UInt32(maxpBytes.count), to: &woff)
        appendBE32(UInt32(maxpBytes.count), to: &woff)
        appendBE32(0, to: &woff)
        // WOFF TableDirectoryEntry 1: name
        woff.append(contentsOf: "name".utf8)
        appendBE32(UInt32(woffTableStart + maxpBytes.count), to: &woff)
        appendBE32(UInt32(nameBytes.count), to: &woff)
        appendBE32(UInt32(nameBytes.count), to: &woff)
        appendBE32(0, to: &woff)
        woff.append(maxpBytes)
        woff.append(nameBytes)
        try woff.write(to: tree.url("synthetic.woff"))
        let woffFaces = FontMetadata.read(tree.url("synthetic.woff"))
        #expect(woffFaces.count == 1)
        #expect(woffFaces[0].family == "Strata Sans")
        #expect(woffFaces[0].glyphCount == 512)

        // 2. Valid Provisioning Profile (.mobileprovision)
        let validProfile = Data("""
        \u{30}\u{80}<?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Name</key><string>Strata Mac Direct Distribution</string>
            <key>TeamName</key><string>Strata Labs SRL</string>
            <key>UUID</key><string>A1B2C3D4-E5F6-7890-ABCD-1234567890AB</string>
            <key>Platform</key><array><string>OSX</string></array>
            <key>ProvisionedDevices</key><array><string>DEV-1</string><string>DEV-2</string></array>
            <key>Entitlements</key><dict><key>com.apple.application-identifier</key><string>TEAM123.dev.strata.app</string></dict>
        </dict>
        </plist>
        """.utf8)
        try validProfile.write(to: tree.url("profile.mobileprovision"))
        let profSummary = try #require(CertificateMetadata.read(tree.url("profile.mobileprovision")))
        #expect(profSummary.isProvisioningProfile)
        #expect(profSummary.subject == "Strata Mac Direct Distribution")
        #expect(profSummary.team == "Strata Labs SRL")
        #expect(profSummary.appID == "TEAM123.dev.strata.app")
        #expect(profSummary.uuid == "A1B2C3D4-E5F6-7890-ABCD-1234567890AB")
        #expect(profSummary.platforms == ["OSX"])
        #expect(profSummary.provisionedDeviceCount == 2)

        // 3. App Bundle (.app) with valid Mach-O universal binary AND with a FIFO executable
        let appURL = tree.root.appending(path: "Sample.app", directoryHint: .isDirectory)
        let contentsURL = appURL.appending(path: "Contents", directoryHint: .isDirectory)
        let macosURL = contentsURL.appending(path: "MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macosURL, withIntermediateDirectories: true)
        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>CFBundleShortVersionString</key><string>2.4</string>
            <key>CFBundleVersion</key><string>240</string>
            <key>LSMinimumSystemVersion</key><string>15.0</string>
            <key>CFBundleExecutable</key><string>Sample</string>
        </dict>
        </plist>
        """
        try Data(infoPlist.utf8).write(to: contentsURL.appending(path: "Info.plist"))
        // Universal Mach-O fat header (0xCAFEBABE, 2 arches: x86_64 0x01000007 and arm64 0x0100000C)
        var fatMachO = Data()
        appendBE32(0xCAFE_BABE, to: &fatMachO)
        appendBE32(2, to: &fatMachO)
        // arch 0: x86_64
        appendBE32(0x0100_0007, to: &fatMachO)
        for _ in 0..<4 { appendBE32(0, to: &fatMachO) }
        // arch 1: arm64
        appendBE32(0x0100_000C, to: &fatMachO)
        for _ in 0..<4 { appendBE32(0, to: &fatMachO) }
        let execURL = macosURL.appending(path: "Sample")
        try fatMachO.write(to: execURL)

        let appSummary = try #require(AppBundleMetadata.read(appURL))
        #expect(appSummary.version == "2.4 (240)")
        #expect(appSummary.architecture == .universal)
        #expect(appSummary.minimumSystemVersion == "15.0")

        // Replace executable with a FIFO and verify AppBundleMetadata.read returns immediately without hanging on SecStaticCodeCreateWithPath
        try FileManager.default.removeItem(at: execURL)
        #expect(mkfifo(execURL.path, 0o600) == 0)
        let fifoAppSummary = try #require(AppBundleMetadata.read(appURL))
        #expect(fifoAppSummary.version == "2.4 (240)")
        #expect(fifoAppSummary.architecture == nil)
        #expect(fifoAppSummary.signedBy == nil)
    }

    // MARK: - Limits: SafeXML, NotebookLoader, TextFile.readSuffix, Archive Formats & SplitView Divider

    @Test func xmlLimitsNotebookLimitsAndTextFileReadSuffixGuardsHold() async throws {
        let tree = try TestTree("suffix.bin", "empty.bin", "huge_outputs.ipynb", "many_diagrams.ipynb", "large_ods.ods")

        // 1. SafeXML limits: maxInputBytes (either side of limit), maxElements, depth > 64, encoding="UTF-7"
        let validXML = Data("<root><item a=\"1\">hello</item></root>".utf8)
        let parsedRoot = try SafeXML.parse(validXML, maxElements: 10, maxInputBytes: validXML.count)
        #expect(parsedRoot.name == "root")
        #expect(throws: SafeXML.ParseFailure.self) {
            _ = try SafeXML.parse(validXML, maxElements: 10, maxInputBytes: validXML.count - 1)
        }
        #expect(throws: SafeXML.ParseFailure.self) {
            _ = try SafeXML.parse(validXML, maxElements: 1, maxInputBytes: 1024)
        }
        let deepOpen = (0..<70).map { "<n\($0)>" }.joined()
        let deepClose = (0..<70).reversed().map { "</n\($0)>" }.joined()
        #expect(throws: SafeXML.ParseFailure.self) {
            _ = try SafeXML.parse(Data((deepOpen + deepClose).utf8))
        }
        #expect(throws: SafeXML.ParseFailure.self) {
            _ = try SafeXML.parse(Data(#"<?xml version="1.0" encoding="UTF-7"?><root/>"#.utf8))
        }

        // 2. TextFile.readSuffix: both sides of limit, empty file, FIFO, and directory
        let payload100 = Data((0..<100).map(UInt8.init))
        try payload100.write(to: tree.url("suffix.bin"))
        let (fullSuffix, size100) = try TextFile.readSuffix(tree.url("suffix.bin"), limit: 100)
        #expect(size100 == 100)
        #expect(fullSuffix == payload100)
        let (tail40, _) = try TextFile.readSuffix(tree.url("suffix.bin"), limit: 40)
        #expect(tail40 == payload100.suffix(40))

        try Data().write(to: tree.url("empty.bin"))
        let (emptySuffix, size0) = try TextFile.readSuffix(tree.url("empty.bin"), limit: 64)
        #expect(size0 == 0)
        #expect(emptySuffix.isEmpty)

        let fifoURL = tree.root.appending(path: "pipe.fifo")
        #expect(mkfifo(fifoURL.path, 0o600) == 0)
        #expect(throws: (any Error).self) {
            _ = try TextFile.readSuffix(fifoURL, limit: 64)
        }
        let dirURL = tree.root.appending(path: "subdir", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            _ = try TextFile.readSuffix(dirURL, limit: 64)
        }

        // 3. NotebookLoader caps outputs per cell (16), caps kernel/language names, and shares one MarkdownRenderer across cells
        let outputsJSON = Array(repeating: #"{"output_type":"stream","text":["out_line\n"]}"#, count: 60).joined(separator: ",")
        let longLang = String(repeating: "python", count: 30)
        let longKernel = String(repeating: "KernelName", count: 20)
        let nbManyOutputs = """
        {
          "metadata": {
            "language_info": { "name": "\(longLang)" },
            "kernelspec": { "display_name": "\(longKernel)" }
          },
          "cells": [{
            "cell_type": "code",
            "execution_count": 1,
            "source": ["x = 1"],
            "outputs": [\(outputsJSON)]
          }]
        }
        """
        try Data(nbManyOutputs.utf8).write(to: tree.url("huge_outputs.ipynb"))
        let cappedDoc = try await NotebookLoader.load(tree.url("huge_outputs.ipynb"))
        #expect(cappedDoc.isTruncated)
        let occurrences = cappedDoc.storage.value.string.components(separatedBy: "out_line").count - 1
        #expect(occurrences == NotebookLoader.maxOutputsPerCell)
        #expect((cappedDoc.customSummary?[1].count ?? 0) <= 48)

        // Pre-cancelled Task must throw CancellationError on NotebookLoader.load
        let cancelledTask = Task { () throws -> MarkdownDocument in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NotebookLoader.load(tree.url("huge_outputs.ipynb"))
        }
        await #expect(throws: CancellationError.self) {
            _ = try await cancelledTask.value
        }

        // 20 markdown cells each with a Mermaid diagram must share the single renderer's 12-diagram limit
        let diagramCells = (0..<20).map { i in
            #"{"cell_type":"markdown","source":["```mermaid\ngraph TD; A\#(i)-->B\#(i);\n```"]}"#
        }.joined(separator: ",")
        try Data("{\"cells\":[\(diagramCells)]}".utf8).write(to: tree.url("many_diagrams.ipynb"))
        let diagramDoc = try await NotebookLoader.load(tree.url("many_diagrams.ipynb"))
        var mermaidCount = 0
        let storage = diagramDoc.storage.value
        storage.enumerateAttribute(MarkdownRenderer.mermaidSource, in: NSRange(location: 0, length: storage.length)) { val, _, _ in
            if val != nil { mermaidCount += 1 }
        }
        #expect(mermaidCount == 12)
    }

    @Test @MainActor func previewSplitViewControllerHidesDividerWhenBrowserIsHidden() throws {
        let browser = NSViewController()
        browser.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let detail = NSViewController()
        detail.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let split = PreviewSplitViewController(browser: browser, detail: detail, preferences: try Prefs.isolated())
        split.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        #expect(split.browserVisible)
        #expect(!split.splitView(split.splitView, shouldHideDividerAt: 0))

        split.showBrowser(false)
        #expect(!split.browserVisible)
        #expect(split.splitView(split.splitView, shouldHideDividerAt: 0))
        let rect = split.splitView(split.splitView, effectiveRect: NSRect(x: 200, y: 0, width: 1, height: 400),
                                   forDrawnRect: NSRect(x: 200, y: 0, width: 1, height: 400), ofDividerAt: 0)
        #expect(rect == .zero)
    }

    // MARK: - Inspector Rows & Search Metadata

    @Test @MainActor func mediaDetailRowsFormatNewHighSignalFieldsCleanly() {
        let details = MediaDetails(
            book: .init(title: "Designing Data-Intensive Applications", author: "Martin Kleppmann", series: "O'Reilly", pages: 12, isChapters: true),
            spreadsheet: .init(sheets: ["Summary", "Q1", "Q2", "Q3"]),
            database: .init(tables: ["users", "orders"], rowCount: 500, columnCount: 2),
            font: .init(family: "Inter", fullName: "Inter Regular", style: "Regular", postScriptName: "Inter-Regular", version: "4.0", copyright: nil, glyphCount: 2800),
            track: .init(name: "Alpine Loop", points: [], distanceMeters: 12_000, elevationGainMeters: 480),
            app: .init(version: "1.2 (45)", architecture: .universal, minimumSystemVersion: "15.0", signedBy: "Apple Inc."),
            model: .init(format: "GGUF", modelName: "Llama-3-8B", architecture: "llama", precision: "Q4_K_M", totalParameters: 8_030_000_000, shapeDescription: nil, tensors: [], sampleValues: [])
        )
        let rows = Dictionary(MediaDetailRows.rows(details), uniquingKeysWith: { _, last in last })
        #expect(rows[String(localized: "Author")] == "Martin Kleppmann")
        #expect(rows[String(localized: "Sheets")] == "4 · Summary, Q1, Q2, …")
        #expect(rows[String(localized: "Tables")] == "2 · users, orders")
        #expect(rows[String(localized: "Family")] == "Inter")
        #expect(rows[String(localized: "Distance")] == "12 km")
        #expect(rows[String(localized: "Elevation gain")] == "+480 m")
        #expect(rows[String(localized: "Architecture")] == "llama")
        #expect(rows[String(localized: "Parameters")] == MLHeaderMetadata.formatParameterCount(8_030_000_000))
    }

    @Test func textExtractorExtractsBoundedHumanMetadataOnlyWhenEnabled() async throws {
        let tree = try TestTree("trail.gpx", "study.ipynb")
        let gpx = """
        <?xml version="1.0"?><gpx><trk><name>Transylvania Ultra</name><trkseg><trkpt lat="45.5" lon="25.5"/></trkseg></trk></gpx>
        """
        try Data(gpx.utf8).write(to: tree.url("trail.gpx"))
        let ipynb = """
        {"cells": [{"cell_type": "markdown", "source": ["#Churn Prediction Model\\n", "## Feature Engineering"]}]}
        """
        try Data(ipynb.utf8).write(to: tree.url("study.ipynb"))

        // Summarizer uses default Options (metadata = false) and must not summarize non-prose formats
        #expect(!Summarizer.canSummarize(tree.url("trail.gpx")))
        #expect(!Summarizer.canSummarize(tree.url("study.ipynb")))

        // With metadata = true, TextExtractor extracts concise human-searchable metadata for structured formats,
        // while images remain gated on options.ocr so photo folders do not crowd out documents in SemanticIndex.
        var options = TextExtractor.Options()
        #expect(!TextExtractor.canExtract(tree.url("photo.jpg"), options: options))
        options.metadata = true
        #expect(!TextExtractor.canExtract(tree.url("photo.jpg"), options: options))
        var ocrOptions = options
        ocrOptions.ocr = true
        #expect(TextExtractor.canExtract(tree.url("photo.jpg"), options: ocrOptions))
        #expect(TextExtractor.canExtract(tree.url("trail.gpx"), options: options))
        #expect(TextExtractor.canExtract(tree.url("study.ipynb"), options: options))

        let gpxExtracted = try #require(await TextExtractor.extract(tree.url("trail.gpx"), options: options))
        #expect(gpxExtracted.text == "Transylvania Ultra")
        #expect(gpxExtracted.text.count <= 256)

        let nbExtracted = try #require(await TextExtractor.extract(tree.url("study.ipynb"), options: options))
        #expect(nbExtracted.text.contains("Churn Prediction Model"))
        #expect(nbExtracted.text.contains("Feature Engineering"))
        #expect(nbExtracted.text.count <= 256)
    }

    @Test @MainActor func previewFooterAndDesignPreviewYieldHorizontalCompressionToSplitViewResizing() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 60))
        let footer = PreviewFooter(frame: NSRect(x: 0, y: 0, width: 540, height: 26))
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.show(["SafeTensors", "6 tensors", "262.14K params", "FP16", "transformer", "StrataCode-Mini-125M"], note: " Truncated")
        host.addSubview(footer)
        let widthConstraint = footer.widthAnchor.constraint(equalToConstant: 240)
        // NSSplitView drags dividers at priority 500 (.dragThatCannotResizeWindow); a constraint at 490 must win over footer text compression.
        widthConstraint.priority = NSLayoutConstraint.Priority(490)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            footer.topAnchor.constraint(equalTo: host.topAnchor),
            widthConstraint,
        ])
        host.layoutSubtreeIfNeeded()
        #expect(footer.frame.width == 240)

        // When plenty of horizontal space is available, the summary label receives its +2 width slack and does not truncate prematurely
        widthConstraint.constant = 540
        footer.show(["SafeTensors", "2 tensors"], note: "Note")
        host.layoutSubtreeIfNeeded()
        let labels = footer.subviews.compactMap { $0 as? NSTextField }
        let summaryLabel = try! #require(labels.first(where: { $0.stringValue.contains("SafeTensors") }))
        #expect(summaryLabel.frame.width >= ceil(summaryLabel.intrinsicContentSize.width) + 1)
    }

    @Test func validX509CertificatesAndArchiveFormatsAndDesignThumbnailFallback() async throws {
        let tree = try TestTree("anchor.cer", "anchor.pem", "large.ods", "book.epub", "comic.cbz", "painting.ora")

        // 1. Valid X.509 Certificate (DER & PEM) from macOS system anchor certificates
        var anchorsRef: CFArray?
        if SecTrustCopyAnchorCertificates(&anchorsRef) == errSecSuccess,
           let anchors = anchorsRef as? [SecCertificate],
           let firstCert = anchors.first {
            let der = SecCertificateCopyData(firstCert) as Data
            try der.write(to: tree.url("anchor.cer"))
            let derSummary = try #require(CertificateMetadata.read(tree.url("anchor.cer")))
            #expect(!derSummary.isProvisioningProfile)
            #expect(derSummary.subject != nil)
            #expect(derSummary.issuer != nil)

            let pem = "-----BEGIN CERTIFICATE-----\n" + der.base64EncodedString(options: [.lineLength64Characters]) + "\n-----END CERTIFICATE-----\n"
            try Data(pem.utf8).write(to: tree.url("anchor.pem"))
            let pemSummary = try #require(CertificateMetadata.read(tree.url("anchor.pem")))
            #expect(pemSummary.subject == derSummary.subject)
        }

        // Pure-Swift uncompressed ZIP archive builder for deterministic archive format tests
        func makeStoredZip(_ entries: [(path: String, data: Data)]) -> Data {
            func crc32(_ data: Data) -> UInt32 {
                var crc: UInt32 = 0xFFFF_FFFF
                for byte in data {
                    crc ^= UInt32(byte)
                    for _ in 0..<8 {
                        crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xEDB8_8320 : 0)
                    }
                }
                return ~crc
            }
            func appendU16(_ v: UInt16, to d: inout Data) {
                var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
            }
            func appendU32(_ v: UInt32, to d: inout Data) {
                var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
            }
            var out = Data()
            var cd = Data()
            for entry in entries {
                let nameBytes = Data(entry.path.utf8)
                let crc = crc32(entry.data)
                let size = UInt32(entry.data.count)
                let localOffset = UInt32(out.count)
                appendU32(0x0403_4B50, to: &out)
                appendU16(20, to: &out)
                appendU16(0, to: &out)
                appendU16(0, to: &out)
                appendU16(0, to: &out)
                appendU16(0, to: &out)
                appendU32(crc, to: &out)
                appendU32(size, to: &out)
                appendU32(size, to: &out)
                appendU16(UInt16(nameBytes.count), to: &out)
                appendU16(0, to: &out)
                out.append(nameBytes)
                out.append(entry.data)

                appendU32(0x0201_4B50, to: &cd)
                appendU16(20, to: &cd)
                appendU16(20, to: &cd)
                appendU16(0, to: &cd)
                appendU16(0, to: &cd)
                appendU16(0, to: &cd)
                appendU16(0, to: &cd)
                appendU32(crc, to: &cd)
                appendU32(size, to: &cd)
                appendU32(size, to: &cd)
                appendU16(UInt16(nameBytes.count), to: &cd)
                appendU16(0, to: &cd)
                appendU16(0, to: &cd)
                appendU16(0, to: &cd)
                appendU16(0, to: &cd)
                appendU32(0, to: &cd)
                appendU32(localOffset, to: &cd)
                cd.append(nameBytes)
            }
            let cdOffset = UInt32(out.count)
            out.append(cd)
            appendU32(0x0605_4B50, to: &out)
            appendU16(0, to: &out)
            appendU16(0, to: &out)
            appendU16(UInt16(entries.count), to: &out)
            appendU16(UInt16(entries.count), to: &out)
            appendU32(UInt32(cd.count), to: &out)
            appendU32(cdOffset, to: &out)
            appendU16(0, to: &out)
            return out
        }

        // 2. ODS with > 600 KB content.xml (above the default 512 KB SafeXML limit, within the 4 MB ODS limit)
        let paddingComment = "<!-- " + String(repeating: "A", count: 600_000) + " -->"
        let odsContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0">
        \(paddingComment)
        <office:body><office:spreadsheet>
        <table:table table:name="Overview"/>
        <table:table table:name="Forecast"/>
        </office:spreadsheet></office:body>
        </office:document-content>
        """
        let odsZip = makeStoredZip([
            ("mimetype", Data("application/vnd.oasis.opendocument.spreadsheet".utf8)),
            ("content.xml", Data(odsContent.utf8)),
        ])
        try odsZip.write(to: tree.url("large.ods"))
        let odsSheets = try #require(await ArchiveMetadata.odsSheetNames(tree.url("large.ods")))
        #expect(odsSheets == ["Overview", "Forecast"])

        // 3. EPUB and CBZ metadata
        let containerXML = """
        <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """
        let opfXML = """
        <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>Systems Programming</dc:title><dc:creator>Ada Lovelace</dc:creator>
        </metadata><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>
        """
        try makeStoredZip([
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/content.opf", Data(opfXML.utf8)),
        ]).write(to: tree.url("book.epub"))
        let epubBook = try #require(await ArchiveMetadata.epubMetadata(tree.url("book.epub")))
        #expect(epubBook.title == "Systems Programming")
        #expect(epubBook.author == "Ada Lovelace")
        #expect(epubBook.pages == 2)
        #expect(epubBook.isChapters)

        let comicInfo = """
        <?xml version="1.0"?><ComicInfo><Series>Starlight</Series><Writer>Jean Moebius</Writer></ComicInfo>
        """
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let pngData = try #require(rep.representation(using: .png, properties: [:]))
        try makeStoredZip([
            ("ComicInfo.xml", Data(comicInfo.utf8)),
            ("page01.png", pngData),
            ("page02.png", pngData),
        ]).write(to: tree.url("comic.cbz"))
        let cbzBook = try #require(await ArchiveMetadata.cbzMetadata(tree.url("comic.cbz")))
        #expect(cbzBook.series == "Starlight")
        #expect(cbzBook.author == "Jean Moebius")
        #expect(cbzBook.pages == 2)

        // 4. ORA / Krita fallback from invalid/unusable mergedimage.png to Thumbnails/thumbnail.png
        try makeStoredZip([
            ("mergedimage.png", Data("not-a-valid-png".utf8)),
            ("Thumbnails/thumbnail.png", pngData),
        ]).write(to: tree.url("painting.ora"))
        let oraSource = try FileReadSource(tree.url("painting.ora"))
        let previewBytes = try await ArchiveMetadata.designPreviewImage(oraSource, ext: "ora")
        #expect(previewBytes == pngData)
    }

    @Test @MainActor func fontPreviewRendersVisibleGlyphsInsideFlippedCanvas() async throws {
        let fontURL = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")
        guard FileManager.default.fileExists(atPath: fontURL.path) else { return }
        let view = FontPreviewView(url: fontURL)
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 420)
        await view.loadingTask?.value
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        var nonEmptyPixels = 0
        for y in stride(from: 20, to: 300, by: 4) {
            for x in stride(from: 20, to: 380, by: 4) {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.1 {
                    nonEmptyPixels += 1
                }
            }
        }
        #expect(nonEmptyPixels > 20)

        let demoDir = URL(fileURLWithPath: "/Users/cristian.pufu/Documents/GitHub/strata/demo-folder")
        let xlsxURL = demoDir.appending(path: "q4-cloud-infrastructure-budget.xlsx")
        if FileManager.default.fileExists(atPath: xlsxURL.path) {
            let xlsxBook = try await XLSXWorkbook.open(xlsxURL)
            #expect(xlsxBook.sheetNames.count == 4)
            let page = try await xlsxBook.page(sheet: 0, page: 0)
            #expect(!page.data.rows.isEmpty)
        }
        let odsURL = demoDir.appending(path: "product-release-roadmap.ods")
        if FileManager.default.fileExists(atPath: odsURL.path) {
            let odsBook = try await ODSWorkbook.open(odsURL)
            #expect(odsBook.sheetNames.count == 3)
            let page = try await odsBook.page(sheet: 0, page: 0)
            #expect(!page.data.rows.isEmpty)
        }
    }
}
