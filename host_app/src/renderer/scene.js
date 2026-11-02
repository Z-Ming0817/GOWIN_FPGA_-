// 真实比例三维场景（单位：米）
// 臂长 0.156 m，摆杆 0.135 m，全部按实物尺寸建模
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

const CFG = {
  armLen: 0.156,
  rodLen: 0.135,
  baseR: 0.075,
  baseH: 0.022,
  armY: 0.084,
  tipTrail: 220
};

export class PendulumScene {
  constructor(canvas, cfg = {}) {
    this.cfg = { ...CFG, ...cfg };
    this.renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    this.renderer.shadowMap.enabled = true;
    this.renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    this.renderer.toneMapping = THREE.ACESFilmicToneMapping;
    this.renderer.toneMappingExposure = 1.05;

    this.scene = new THREE.Scene();
    this.scene.background = new THREE.Color('#0b0f14');
    this.scene.fog = new THREE.Fog('#0b0f14', 1.4, 3.2);

    this.camera = new THREE.PerspectiveCamera(38, 1, 0.01, 20);
    this.camera.position.set(0.32, 0.24, 0.34);

    this.controls = new OrbitControls(this.camera, canvas);
    this.controls.target.set(0, 0.12, 0);
    this.controls.enableDamping = true;
    this.controls.dampingFactor = 0.08;
    this.controls.minDistance = 0.12;
    this.controls.maxDistance = 2.2;
    this.controls.maxPolarAngle = Math.PI * 0.52;

    this.targetTheta = 0;
    this.targetPhi = 0;
    this.theta = 0;
    this.phi = 0;
    this.firstSync = false;

    this.buildLights();
    this.buildGround();
    this.buildRig();
    this.buildTrail();

    this.resize();
  }

  buildLights() {
    this.scene.add(new THREE.HemisphereLight('#cfe6ff', '#0e1620', 1.15));

    const key = new THREE.DirectionalLight('#ffffff', 2.0);
    key.position.set(0.5, 0.9, 0.45);
    key.castShadow = true;
    key.shadow.mapSize.set(1024, 1024);
    key.shadow.camera.near = 0.1;
    key.shadow.camera.far = 3;
    key.shadow.camera.left = -0.5;
    key.shadow.camera.right = 0.5;
    key.shadow.camera.top = 0.5;
    key.shadow.camera.bottom = -0.5;
    this.scene.add(key);

    const rim = new THREE.DirectionalLight('#5aa8ff', 0.8);
    rim.position.set(-0.6, 0.4, -0.5);
    this.scene.add(rim);
  }

  buildGround() {
    const grid = new THREE.GridHelper(1.2, 24, '#1d2c3a', '#141e28');
    grid.position.y = 0;
    this.scene.add(grid);

    const ground = new THREE.Mesh(
      new THREE.CircleGeometry(0.6, 64),
      new THREE.MeshStandardMaterial({ color: '#0d141b', roughness: 0.95, metalness: 0.05 })
    );
    ground.rotation.x = -Math.PI / 2;
    ground.position.y = -0.001;
    ground.receiveShadow = true;
    this.scene.add(ground);

    // 臂末端扫过的圆周（半径 = 臂长）
    const ring = new THREE.Mesh(
      new THREE.RingGeometry(this.cfg.armLen - 0.0008, this.cfg.armLen + 0.0008, 128),
      new THREE.MeshBasicMaterial({ color: '#2b6f9a', transparent: true, opacity: 0.55, side: THREE.DoubleSide })
    );
    ring.rotation.x = -Math.PI / 2;
    ring.position.y = 0.0015;
    this.scene.add(ring);
  }

  buildRig() {
    // 底座
    const base = new THREE.Mesh(
      new THREE.CylinderGeometry(this.cfg.baseR, this.cfg.baseR, this.cfg.baseH, 48),
      new THREE.MeshStandardMaterial({ color: '#222d38', roughness: 0.55, metalness: 0.6 })
    );
    base.position.y = this.cfg.baseH / 2;
    base.castShadow = true;
    base.receiveShadow = true;
    this.scene.add(base);

    // 电机
    const motor = new THREE.Mesh(
      new THREE.CylinderGeometry(0.028, 0.028, 0.062, 32),
      new THREE.MeshStandardMaterial({ color: '#3a4a5a', roughness: 0.4, metalness: 0.75 })
    );
    motor.position.y = this.cfg.baseH + 0.031;
    motor.castShadow = true;
    this.scene.add(motor);

    // 竖直轴套
    const shaft = new THREE.Mesh(
      new THREE.CylinderGeometry(0.006, 0.006, 0.03, 20),
      new THREE.MeshStandardMaterial({ color: '#8b9aa8', roughness: 0.3, metalness: 0.9 })
    );
    shaft.position.y = this.cfg.armY - 0.012;
    this.scene.add(shaft);

    // 绕竖直轴旋转 → 臂角 φ
    this.yawGroup = new THREE.Group();
    this.yawGroup.position.y = this.cfg.armY;
    this.scene.add(this.yawGroup);

    const armGeo = new THREE.BoxGeometry(this.cfg.armLen, 0.009, 0.016);
    const arm = new THREE.Mesh(
      armGeo,
      new THREE.MeshStandardMaterial({ color: '#e8853c', roughness: 0.45, metalness: 0.25 })
    );
    arm.position.x = this.cfg.armLen / 2;
    arm.castShadow = true;
    this.yawGroup.add(arm);
    this.armMesh = arm;
    this.baseArmOpacity = 1;

    // 臂末端的铰链座
    const hub = new THREE.Mesh(
      new THREE.CylinderGeometry(0.013, 0.013, 0.02, 24),
      new THREE.MeshStandardMaterial({ color: '#9aa8b6', roughness: 0.35, metalness: 0.85 })
    );
    hub.position.x = this.cfg.armLen;
    hub.castShadow = true;
    this.yawGroup.add(hub);

    // 绕水平轴旋转 → 摆角 θ（0 = 直立向上）
    this.pitchGroup = new THREE.Group();
    this.pitchGroup.position.x = this.cfg.armLen;
    this.yawGroup.add(this.pitchGroup);

    const rod = new THREE.Mesh(
      new THREE.CylinderGeometry(0.0045, 0.0045, this.cfg.rodLen, 20),
      new THREE.MeshStandardMaterial({ color: '#4cc9f0', roughness: 0.3, metalness: 0.35, emissive: '#0b3346', emissiveIntensity: 0.9 })
    );
    rod.position.y = this.cfg.rodLen / 2;
    rod.castShadow = true;
    this.pitchGroup.add(rod);

    const bob = new THREE.Mesh(
      new THREE.SphereGeometry(0.011, 24, 16),
      new THREE.MeshStandardMaterial({ color: '#7ee0ff', roughness: 0.2, metalness: 0.3, emissive: '#1c6f8c', emissiveIntensity: 0.7 })
    );
    bob.position.y = this.cfg.rodLen;
    bob.castShadow = true;
    this.pitchGroup.add(bob);
    this.bob = bob;
  }

  buildTrail() {
    const geo = new THREE.BufferGeometry();
    const pos = new Float32Array(this.cfg.tipTrail * 3);
    geo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    geo.setDrawRange(0, 0);
    this.trailPos = pos;
    this.trailCount = 0;
    this.trail = new THREE.Line(
      geo,
      new THREE.LineBasicMaterial({ color: '#2f8fb8', transparent: true, opacity: 0.75 })
    );
    this.scene.add(this.trail);
    this.trailDirty = false;
  }

  pushTrail() {
    const tip = new THREE.Vector3();
    this.bob.getWorldPosition(tip);
    const n = this.cfg.tipTrail;
    if (this.trailCount >= n) {
      this.trailPos.copyWithin(0, 3);
      this.trailCount = n - 1;
    }
    const i = this.trailCount * 3;
    this.trailPos[i] = tip.x;
    this.trailPos[i + 1] = tip.y;
    this.trailPos[i + 2] = tip.z;
    this.trailCount += 1;
    this.trail.geometry.setDrawRange(0, this.trailCount);
    this.trail.geometry.attributes.position.needsUpdate = true;
  }

  clearTrail() {
    this.trailCount = 0;
    this.trail.geometry.setDrawRange(0, 0);
  }

  /** 输入：theta/phi 单位度 */
  setPose(thetaDeg, phiDeg) {
    if (!this.firstSync) {
      this.theta = thetaDeg;
      this.phi = phiDeg;
      this.firstSync = true;
    }
    this.targetTheta = thetaDeg;
    this.targetPhi = phiDeg;
  }

  /** 起摆模式下固件用 A= 字段发占空比，臂角未知 —— 用半透明提示 */
  setPhiKnown(known) {
    const mat = this.armMesh.material;
    if (known) {
      mat.transparent = false;
      mat.opacity = 1;
    } else {
      mat.transparent = true;
      mat.opacity = 0.32;
    }
    mat.needsUpdate = true;
  }

  reset() {
    this.firstSync = false;
    this.theta = 0;
    this.phi = 0;
    this.clearTrail();
  }

  resize() {
    const canvas = this.renderer.domElement;
    const rect = canvas.getBoundingClientRect();
    const w = Math.max(200, Math.round(rect.width));
    const h = Math.max(200, Math.round(rect.height));
    this.renderer.setSize(w, h, false);
    this.camera.aspect = w / h;
    this.camera.updateProjectionMatrix();
  }

  step() {
    // 20Hz 数据 → 60fps 插值，避免跳变
    let dTheta = this.targetTheta - this.theta;
    while (dTheta > 180) dTheta -= 360;
    while (dTheta < -180) dTheta += 360;
    this.theta += dTheta * 0.22;

    let dPhi = this.targetPhi - this.phi;
    while (dPhi > 180) dPhi -= 360;
    while (dPhi < -180) dPhi += 360;
    this.phi += dPhi * 0.25;

    this.yawGroup.rotation.y = (-this.phi * Math.PI) / 180;
    this.pitchGroup.rotation.x = (this.theta * Math.PI) / 180;

    this.controls.update();
    this.renderer.render(this.scene, this.camera);
  }
}