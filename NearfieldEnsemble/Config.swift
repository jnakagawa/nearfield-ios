import Foundation

// Codable mirrors of the config contracts (spec §4.2, §6.4). Only the fields
// the Hum phase consumes are modeled; unknown JSON keys are ignored by design
// so config evolution doesn't break older builds.

struct Scale: Codable {
    let baseFreqHz: Double
    let spectrum: Spectrum
    let pseudoOctaveRatio: Double
    let scaleCents: [Double]
    let dipIntervalsCents: [Double]

    struct Spectrum: Codable {
        let ratios: [Double]
        let amps: [Double]
    }

    enum CodingKeys: String, CodingKey {
        case baseFreqHz = "base_freq_hz"
        case spectrum
        case pseudoOctaveRatio = "pseudo_octave_ratio"
        case scaleCents = "scale_cents"
        case dipIntervalsCents = "dip_intervals_cents"
    }
}

struct Params: Codable {
    let breath: Breath
    let timbre: Timbre?

    struct Breath: Codable {
        let periodS: Double
        let ensembleDepth: Double
        enum CodingKeys: String, CodingKey {
            case periodS = "period_s"
            case ensembleDepth = "ensemble_depth"
        }
    }

    struct Timbre: Codable {
        let loudnessRefHz: Double
        let loudnessExponent: Double
        let shelfFreqHz: Double
        let shelfGainDb: Double
        let lowpassHz: Double
        let reverbWet: Double
        enum CodingKeys: String, CodingKey {
            case loudnessRefHz = "loudness_ref_hz"
            case loudnessExponent = "loudness_exponent"
            case shelfFreqHz = "shelf_freq_hz"
            case shelfGainDb = "shelf_gain_db"
            case lowpassHz = "lowpass_hz"
            case reverbWet = "reverb_wet"
        }
    }
}

struct AssignMessage: Codable {
    let type: String
    let participantId: Int
    let role: String
    let degreeIndex: Int
    let register: Int
    let pitchHz: Double
    let scale: Scale
    let params: Params
    let performanceId: Int

    enum CodingKeys: String, CodingKey {
        case type
        case participantId = "participant_id"
        case role
        case degreeIndex = "degree_index"
        case register
        case pitchHz = "pitch_hz"
        case scale
        case params
        case performanceId = "performance_id"
    }
}
