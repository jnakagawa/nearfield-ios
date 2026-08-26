#!/usr/bin/env python3
"""
Caustic lens generator + independent ray-trace tester, for the Nearfield mark.

Method: Matt Ferraro's "caustics engineering" (mattferraro.dev/posts/caustics-engineering),
which builds on Yue et al., "Poisson-Based Continuous Surface Generation for Goal-Based
Caustics." A clear slab has a flat bottom and a subtly shaped top; collimated light
refracts through the shaped top and redistributes into a target image (the caustic) on a
screen a distance `d` below.

Pipeline
  1) prepare_target  – load image -> grayscale, optional invert/blur, epsilon floor,
                       normalize to mean 1 (mass = area, so light is conserved).
  2) solve_transport – linearized Monge-Ampere / optimal transport by Poisson relaxation:
                       find a potential Phi so the map X -> X + grad(Phi) sends uniform
                       incoming light to the target distribution. (Neumann BC via DCT.)
  3) heights         – thin-prism relation: a ray at surface slope grad(h) deflects by
                       (n-1)*grad(h) and, after distance d, lands at X + d(n-1)grad(h).
                       Matching that to X + grad(Phi) gives h = Phi / (d (n-1)).
  4) build_mesh      – shaped top + flat bottom + walls -> watertight solid -> STL.
  5) simulate        – INDEPENDENT check: shoot parallel rays down, do full two-surface
                       vector Snell refraction, propagate to the screen, histogram the
                       landings -> the caustic the lens actually makes. Compare to target.

deps: numpy, scipy, pillow, trimesh
"""
import argparse, os
import numpy as np
from scipy.fft import dctn, idctn
from scipy.ndimage import gaussian_filter
from PIL import Image
import trimesh


# ---- Poisson solver: laplacian(phi) = f, Neumann (zero-flux) BC, via DCT-II ----
def poisson_neumann(f, h):
    f = f - f.mean()                       # solvability (Neumann needs zero-mean RHS)
    N0, N1 = f.shape
    fhat = dctn(f, type=2, norm="ortho")
    ki = (2 * np.cos(np.pi * np.arange(N0) / N0) - 2) / h**2   # 3-pt Laplacian eigenvalues
    kj = (2 * np.cos(np.pi * np.arange(N1) / N1) - 2) / h**2
    denom = ki[:, None] + kj[None, :]
    denom[0, 0] = 1.0
    phih = fhat / denom
    phih[0, 0] = 0.0
    return idctn(phih, type=2, norm="ortho")


def grad(a, h):
    gy, gx = np.gradient(a, h)             # note: axis0=y, axis1=x
    return gx, gy


def bilinear(img, px, py, L):
    """Sample img (NxN over [0,L]^2, cell-centered) at physical coords (px,py)."""
    N = img.shape[0]
    fx = np.clip(px / L * N - 0.5, 0, N - 1.001)
    fy = np.clip(py / L * N - 0.5, 0, N - 1.001)
    x0 = np.floor(fx).astype(int); y0 = np.floor(fy).astype(int)
    tx = fx - x0; ty = fy - y0
    return (img[y0, x0]     * (1 - tx) * (1 - ty) +
            img[y0, x0 + 1] * tx * (1 - ty) +
            img[y0 + 1, x0] * (1 - tx) * ty +
            img[y0 + 1, x0 + 1] * tx * ty)


# ---- 1) target -------------------------------------------------------------
def prepare_target(path, N, invert, blur, floor, demo=None):
    if demo == "disk":
        yy, xx = np.mgrid[0:N, 0:N] / N - 0.5
        img = ((xx**2 + yy**2) < 0.22**2).astype(float)
    elif demo == "ring":
        yy, xx = np.mgrid[0:N, 0:N] / N - 0.5
        r = np.hypot(xx, yy); img = ((r < 0.33) & (r > 0.22)).astype(float)
    else:
        im = Image.open(path).convert("L").resize((N, N), Image.LANCZOS)
        img = np.asarray(im, float) / 255.0
        if invert:
            img = 1.0 - img
    if blur > 0:
        img = gaussian_filter(img, blur)
    img = img / img.max()
    img = floor + (1 - floor) * img        # epsilon floor: every cell gets some light
    img = img / img.mean()                 # normalize: mean brightness = 1 (mass = area)
    return img


# ---- 2) optimal transport (Poisson relaxation) -----------------------------
def solve_transport(target, L, iters, alpha, verbose=True):
    N = target.shape[0]; h = L / N
    xs = (np.arange(N) + 0.5) * h
    PX, PY = np.meshgrid(xs, xs)           # current landing positions (start = identity)
    Phi = np.zeros((N, N))                 # accumulated transport potential
    for it in range(iters):
        T = bilinear(target, PX, PY, L)
        rhs = 1.0 / T - 1.0                # det(I+Hess phi) ~ 1/target  =>  lap phi = 1/T-1
        phi = poisson_neumann(rhs, h)
        gx, gy = grad(phi, h)
        # anti-fold damping: cap the step so no ray overtakes its neighbour this iter
        mv = np.hypot(gx, gy).max() + 1e-12
        step = min(alpha, 0.4 * h / mv)
        PX += step * gx; PY += step * gy
        Phi += step * phi
        if verbose and (it % 10 == 0 or it == iters - 1):
            err = np.abs(T - 1).mean()
            print(f"  iter {it:3d}  mean|bright-target| {err:.4f}  step {step:.2e}")
    return Phi


# ---- 3) heights ------------------------------------------------------------
def heights_from_potential(Phi, n, d):
    # A downward ray on a surface rising in +x bends toward the (-hx,-hy,1) normal,
    # so it deflects toward -x: landing = X - d(n-1) grad(h). Matching X + grad(Phi)
    # gives h = -Phi / (d (n-1)).
    h = -Phi / (d * (n - 1.0))
    h -= h.min()
    return h


# ---- 4) solid mesh ---------------------------------------------------------
def build_mesh(hfield, L, base):
    N = hfield.shape[0]; h = L / N
    xs = (np.arange(N) + 0.5) * h
    X, Y = np.meshgrid(xs, xs)
    ztop = base + hfield
    # vertices: top grid then bottom grid
    top = np.column_stack([X.ravel(), Y.ravel(), ztop.ravel()])
    bot = np.column_stack([X.ravel(), Y.ravel(), np.zeros(N * N)])
    V = np.vstack([top, bot]); nb = N * N
    def vid(i, j, layer): return layer * nb + i * N + j
    F = []
    for i in range(N - 1):
        for j in range(N - 1):
            a, b, c, dd = vid(i, j, 0), vid(i, j + 1, 0), vid(i + 1, j + 1, 0), vid(i + 1, j, 0)
            F += [[a, b, c], [a, c, dd]]                      # top (up)
            a2, b2, c2, d2 = vid(i, j, 1), vid(i, j + 1, 1), vid(i + 1, j + 1, 1), vid(i + 1, j, 1)
            F += [[a2, c2, b2], [a2, d2, c2]]                 # bottom (down)
    for j in range(N - 1):                                    # walls (y=0, y=max)
        F += [[vid(0, j, 0), vid(0, j, 1), vid(0, j + 1, 1)], [vid(0, j, 0), vid(0, j + 1, 1), vid(0, j + 1, 0)]]
        F += [[vid(N - 1, j, 0), vid(N - 1, j + 1, 1), vid(N - 1, j, 1)], [vid(N - 1, j, 0), vid(N - 1, j + 1, 0), vid(N - 1, j + 1, 1)]]
    for i in range(N - 1):                                    # walls (x=0, x=max)
        F += [[vid(i, 0, 0), vid(i + 1, 0, 1), vid(i, 0, 1)], [vid(i, 0, 0), vid(i + 1, 0, 0), vid(i + 1, 0, 1)]]
        F += [[vid(i, N - 1, 0), vid(i, N - 1, 1), vid(i + 1, N - 1, 1)], [vid(i, N - 1, 0), vid(i + 1, N - 1, 1), vid(i + 1, N - 1, 0)]]
    m = trimesh.Trimesh(vertices=V, faces=np.array(F), process=True)
    return m


# ---- 5) independent ray-trace test (full two-surface vector Snell) ----------
def refract(I, Nrm, eta):
    """Vector Snell. I,Nrm unit rows; eta = n_in/n_out. Returns refracted dirs (NaN if TIR)."""
    cosi = -(I * Nrm).sum(1)
    k = 1 - eta**2 * (1 - cosi**2)
    out = eta * I + (eta * cosi - np.sqrt(np.clip(k, 0, None)))[:, None] * Nrm
    out[k < 0] = np.nan
    return out


def simulate(hfield, L, n, d, base, n_rays=900, res=360, supersample=True):
    N = hfield.shape[0]; hcell = L / N
    hx, hy = grad(hfield, hcell)
    # ray entry grid on the top surface
    g = (np.arange(n_rays) + 0.5) / n_rays * L
    RX, RY = np.meshgrid(g, g)
    # surface normal of z = base + h(x,y):  n ~ (-hx,-hy,1)
    sx = bilinear(hx, RX.ravel(), RY.ravel(), L)
    sy = bilinear(hy, RX.ravel(), RY.ravel(), L)
    Nrm = np.column_stack([-sx, -sy, np.ones_like(sx)])
    Nrm /= np.linalg.norm(Nrm, axis=1, keepdims=True)
    I = np.tile([0, 0, -1.0], (Nrm.shape[0], 1))              # collimated, straight down
    d1 = refract(I, Nrm, 1.0 / n)                             # air -> resin
    # propagate to flat bottom plane z=0 (entry z ~ base+h; use base as mean plane)
    zt = base + bilinear(hfield, RX.ravel(), RY.ravel(), L)
    P = np.column_stack([RX.ravel(), RY.ravel(), zt])
    t = (0.0 - P[:, 2]) / d1[:, 2]
    P2 = P + t[:, None] * d1
    flat = np.tile([0, 0, -1.0], (P2.shape[0], 1))
    d2 = refract(d1, flat, n / 1.0)                          # resin -> air (flat exit)
    # propagate to screen z = -d
    t2 = (-d - P2[:, 2]) / d2[:, 2]
    S = P2 + t2[:, None] * d2
    ok = np.isfinite(S[:, 0]) & np.isfinite(S[:, 1])
    # histogram landings, centered on the lens footprint
    rng = [[-0.25 * L, 1.25 * L], [-0.25 * L, 1.25 * L]]
    H, _, _ = np.histogram2d(S[ok, 1], S[ok, 0], bins=res, range=rng)
    if supersample:
        H = gaussian_filter(H, 0.8)
    return H


def save_gray(arr, path, gamma=0.6):
    a = arr / (arr.max() + 1e-9)
    a = np.power(a, gamma)
    Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8)).save(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", default=None)
    ap.add_argument("--demo", default=None, choices=[None, "disk", "ring"])
    ap.add_argument("--out", default="out")
    ap.add_argument("-N", type=int, default=256)
    ap.add_argument("--L", type=float, default=100.0, help="lens size mm")
    ap.add_argument("--n", type=float, default=1.51, help="refractive index (clear resin)")
    ap.add_argument("--d", type=float, default=250.0, help="throw distance mm")
    ap.add_argument("--base", type=float, default=3.0, help="base thickness mm")
    ap.add_argument("--iters", type=int, default=40)
    ap.add_argument("--alpha", type=float, default=0.8)
    ap.add_argument("--invert", action="store_true")
    ap.add_argument("--blur", type=float, default=1.0)
    ap.add_argument("--floor", type=float, default=0.06)
    ap.add_argument("--rays", type=int, default=900, help="ray-trace grid per side")
    ap.add_argument("--res", type=int, default=360, help="sim caustic image resolution")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    print("1) target"); tgt = prepare_target(args.image, args.N, args.invert, args.blur, args.floor, args.demo)
    save_gray(tgt, f"{args.out}/target.png", gamma=1.0)
    print("2) transport"); Phi = solve_transport(tgt, args.L, args.iters, args.alpha)
    print("3) heights"); hf = heights_from_potential(Phi, args.n, args.d)
    relief = hf.max() - hf.min()
    print(f"   relief peak-to-valley: {relief:.3f} mm   (base {args.base} mm)")
    print("4) mesh -> STL"); m = build_mesh(hf, args.L, args.base)
    stl = f"{args.out}/nearfield_caustic_lens.stl"; m.export(stl)
    print(f"   watertight={m.is_watertight}  verts={len(m.vertices)}  faces={len(m.faces)}  -> {stl}")
    print("5) ray-trace test"); H = simulate(hf, args.L, args.n, args.d, args.base, n_rays=args.rays, res=args.res)
    save_gray(H, f"{args.out}/caustic_sim.png")
    print(f"   simulated caustic -> {args.out}/caustic_sim.png")
    print("DONE:", os.path.abspath(args.out))


if __name__ == "__main__":
    main()
