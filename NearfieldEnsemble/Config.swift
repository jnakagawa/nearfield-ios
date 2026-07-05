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
    let sensing: Sensing
    let wind: Wind
    let encounter: Encounter
    let bloom: Bloom
    let slew: Slew
    let shimmerAm: ShimmerAm
    let drift: Drift
    let roles: [String: Role]

    enum CodingKeys: String, CodingKey {
        case breath, timbre, sensing, wind, encounter, bloom, slew, drift, roles
        case shimmerAm = "shimmer_am"
    }

    struct Breath: Codable {
        let periodS: Double
        let ensembleDepth: Double
        enum CodingKeys: String, CodingKey {
            case periodS = "period_s"
            case ensembleDepth = "ensemble_depth"
        }
    }

    struct Sensing: Codable {
        let tickHz: Double
        let rssiEmaTauS: Double
        let rssiNearEnterDbm: Double
        let rssiNearExitDbm: Double
        let rssiMidEnterDbm: Double
        let rssiMidExitDbm: Double
        let farTimeoutS: Double
        let encounterOnS: Double
        let encounterOffS: Double
        enum CodingKeys: String, CodingKey {
            case tickHz = "tick_hz"
            case rssiEmaTauS = "rssi_ema_tau_s"
            case rssiNearEnterDbm = "rssi_near_enter_dbm"
            case rssiNearExitDbm = "rssi_near_exit_dbm"
            case rssiMidEnterDbm = "rssi_mid_enter_dbm"
            case rssiMidExitDbm = "rssi_mid_exit_dbm"
            case farTimeoutS = "far_timeout_s"
            case encounterOnS = "encounter_on_s"
            case encounterOffS = "encounter_off_s"
        }
    }

    struct Wind: Codable {
        let alphaMotionPerS: Double
        let alphaNoveltyPerS: Double
        let tauWindS: Double
        let motionAccelMaxG: Double
        let motionEmaTauS: Double
        let noveltyWindowS: Double
        enum CodingKeys: String, CodingKey {
            case alphaMotionPerS = "alpha_motion_per_s"
            case alphaNoveltyPerS = "alpha_novelty_per_s"
            case tauWindS = "tau_wind_s"
            case motionAccelMaxG = "motion_accel_max_g"
            case motionEmaTauS = "motion_ema_tau_s"
            case noveltyWindowS = "novelty_window_s"
        }
    }

    struct Encounter: Codable {
        let tauAttackS: Double
        let tauReleaseS: Double
        let tauFamiliarityS: Double
        let tauFamiliarityReleaseS: Double
        enum CodingKeys: String, CodingKey {
            case tauAttackS = "tau_attack_s"
            case tauReleaseS = "tau_release_s"
            case tauFamiliarityS = "tau_familiarity_s"
            case tauFamiliarityReleaseS = "tau_familiarity_release_s"
        }
    }

    struct Bloom: Codable {
        let betaFamiliarity: Double
        let gainBase: Double
        let gainWind: Double
        let partialThresholds: [Double]
        let thresholdWidth: Double
        let gainAttackS: Double
        let gainReleaseS: Double
        enum CodingKeys: String, CodingKey {
            case betaFamiliarity = "beta_familiarity"
            case gainBase = "gain_base"
            case gainWind = "gain_wind"
            case partialThresholds = "partial_thresholds"
            case thresholdWidth = "threshold_width"
            case gainAttackS = "gain_attack_s"
            case gainReleaseS = "gain_release_s"
        }
    }

    struct Slew: Codable {
        let centsStart: Double
        let centsPerSMax: Double
        let dipMaxDistanceCents: Double
        enum CodingKeys: String, CodingKey {
            case centsStart = "cents_start"
            case centsPerSMax = "cents_per_s_max"
            case dipMaxDistanceCents = "dip_max_distance_cents"
        }
    }

    struct ShimmerAm: Codable {
        let rateBaseHz: Double
        let rateMotionHz: Double
        let depthWind: Double
        enum CodingKeys: String, CodingKey {
            case rateBaseHz = "rate_base_hz"
            case rateMotionHz = "rate_motion_hz"
            case depthWind = "depth_wind"
        }
    }

    struct Drift: Codable {
        let fingerprintMaxCents: Double
        let fingerprintTauS: Double
        let fingerprintAmplitude: Double
        let roleMultipliers: [String: Double]
        let ombakEnabled: Bool
        let ombakRefHz: Double
        enum CodingKeys: String, CodingKey {
            case fingerprintMaxCents = "fingerprint_max_cents"
            case fingerprintTauS = "fingerprint_tau_s"
            case fingerprintAmplitude = "fingerprint_amplitude"
            case roleMultipliers = "role_multipliers"
            case ombakEnabled = "ombak_enabled"
            case ombakRefHz = "ombak_ref_hz"
        }
    }

    struct Role: Codable {
        let maxPartials: Int
        let bloomScale: Double
        let motionGate: Bool
        let slew: Bool
        let baseGain: Double
        let amDepthScale: Double
        enum CodingKeys: String, CodingKey {
            case maxPartials = "max_partials"
            case bloomScale = "bloom_scale"
            case motionGate = "motion_gate"
            case slew
            case baseGain = "base_gain"
            case amDepthScale = "am_depth_scale"
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
