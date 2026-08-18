import CoreMotion

// Motion energy (spec §5.1): m = clamp(EMA_1s(|userAcceleration|) / a_max, 0, 1)
// with a_max = 0.5 g, putting a calm walk around 0.5.
final class MotionSensor: ObservableObject {
    @Published private(set) var motion: Double = 0

    private let manager = CMMotionManager()
    private var ema = 0.0
    private var params: Params?

    func start(params: Params) {
        self.params = params
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 20.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] dm, _ in
            guard let self, let dm, let p = self.params else { return }
            let a = dm.userAcceleration
            let mag = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            self.ema += (mag - self.ema) * emaAlpha(dt: 1.0 / 20.0, tau: p.wind.motionEmaTauS)
            self.motion = clamp(self.ema / p.wind.motionAccelMaxG, 0, 1)
        }
    }
}
