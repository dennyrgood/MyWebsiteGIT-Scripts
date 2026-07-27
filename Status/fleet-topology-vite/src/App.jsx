import { useState } from "react";

const W = 1600, H = 1150;
const NW = 84, NH = 38;

const Y = {
  y1:  60,
  y2: 180,
  y3: 320,
  y4: 460,
  y5: 600,
  y6: 740,
  y7: 880,
  y8: 1020,
};

// Services per node — shown as small italic text when SVC filter is on
const services = {
  SI:    ["ComfyUI", "Ollama"],
  SC:    ["Ollama", "OpenWebUI", "ComfyUI", "Fleet Status", "Immich bkp (VM)"],
  SW:    ["Immich primary"],
  AMSDT: ["OpenWebUI", "Flask APIs", "Fleet Status"],
  MM:    ["Plex primary", "Syncthing hub"],
  ZB:    ["Internet gateway"],
  W:     ["WiFi AP"],
  HUB24: ["24-port switch"],
  NAS:   ["Network storage"],
};

// 2026-07-26 23:30 UTC — v8: ZC→Ziggo Media Center, Magic LAN Powerline, Micro USB Device, Rechtsdoor, no abbr block
const nodes = {
  STRIP18:{ label:"18-socket\n(mains)", x:500,  y:Y.y1, type:"strip" },
  US:     { label:"US strip\n(mains)",  x:1050, y:Y.y1, type:"strip" },
  MLSTRIP:{ label:"Magic LAN\nPowerline",  x:1200, y:Y.y1, type:"strip" },
  AC:     { label:"A/C",               x:400,  y:Y.y2, type:"device" },
  F:      { label:"Fan",               x:520,  y:Y.y2, type:"device" },
  ME:     { label:"MM Dock",           x:900,  y:Y.y2, type:"device" },
  THD:    { label:"Temp HDD",          x:1000, y:Y.y2, type:"device" },
  HUE:    { label:"Hue",               x:1100, y:Y.y2, type:"device" },
  USB8:   { label:"8-port USB",        x:400,  y:Y.y3, type:"usb" },
  HUB24:  { label:"24-port hub",       x:600,  y:Y.y3, type:"device" },
  ZB:     { label:"Ziggo WAN",         x:1300, y:Y.y3, type:"device" },
  D:      { label:"Dyon TV",           x:280,  y:Y.y4, type:"device" },
  S:      { label:"Samsung",           x:900,  y:Y.y4, type:"device" },
  W:      { label:"WiFi\nTP-Link",     x:1300, y:Y.y4, type:"device" },
  MM:     { label:"Mac Mini",          x:160,  y:Y.y5, type:"device" },
  NS:     { label:"Nintendo\nSwitch",  x:280,  y:Y.y5, type:"device" },
  G:      { label:"Google TV",         x:400,  y:Y.y5, type:"device" },
  ZC:     { label:"Ziggo Media\nCenter",             x:700,  y:Y.y5, type:"device" },
  NAS:    { label:"NAS\nUgreen",       x:820,  y:Y.y5, type:"device" },
  WYZ:    { label:"Wyze Cam",          x:1450, y:Y.y5, type:"device" },
  GH:     { label:"Google Home",       x:60,   y:Y.y6, type:"device" },
  C:      { label:"Clock",             x:180,  y:Y.y6, type:"device" },
  FIRE:   { label:"Micro USB\nDevice",       x:300,  y:Y.y6, type:"device" },
  TADO:   { label:"Tado",              x:420,  y:Y.y6, type:"device" },
  RD:     { label:"Rechtsdoor",         x:540,  y:Y.y6, type:"device" },
  SI:     { label:"IB\nImg Beast",     x:700,  y:Y.y6, type:"device" },
  SC:     { label:"CWH\nChatWH",       x:820,  y:Y.y6, type:"device" },
  SW:     { label:"WBU\nWrkbnch",      x:960,  y:Y.y6, type:"device" },
  GL1:    { label:"GL-RM1\n→IB",       x:700,  y:Y.y7, type:"kvm" },
  GL2:    { label:"GL-RM1\n→CWH",      x:820,  y:Y.y7, type:"kvm" },
  GL3:    { label:"GL-RM1\n→WBU",      x:960,  y:Y.y7, type:"kvm" },
  RDHUB:  { label:"Rechtsdoor\nHub",    x:540,  y:Y.y7, type:"device" },
  AMSDT:  { label:"amsDT\nAmst. Desktop", x:460, y:Y.y8, type:"device" },
  PRUSA:  { label:"Prusa\n3D Printer",    x:620, y:Y.y8, type:"device" },
};

const RED   = "#C62828";
const GREEN = "#2E7D32";
const BLACK = "#212121";
const BLUE  = "#1565C0";
const KVM   = "#6A1B9A";
const SVC   = "#00695C"; // teal for service labels

const edges = [
  { from:"STRIP18", to:"AC",      color:RED },
  { from:"STRIP18", to:"F",       color:RED },
  { from:"STRIP18", to:"D",       color:RED },
  { from:"STRIP18", to:"S",       color:RED },
  { from:"STRIP18", to:"MM",      color:RED },
  { from:"STRIP18", to:"NS",      color:RED },
  { from:"STRIP18", to:"ZC",      color:RED },
  { from:"STRIP18", to:"NAS",     color:RED },
  { from:"STRIP18", to:"SI",      color:RED },
  { from:"STRIP18", to:"SC",      color:RED },
  { from:"STRIP18", to:"W",       color:RED },
  { from:"STRIP18", to:"HUB24",   color:RED },
  { from:"STRIP18", to:"USB8",    color:RED },
  { from:"US",      to:"ME",      color:RED },
  { from:"US",      to:"THD",     color:RED },
  { from:"US",      to:"HUE",     color:RED },
  { from:"MLSTRIP", to:"SW",      color:RED },
  { from:"USB8",    to:"GH",      color:GREEN },
  { from:"USB8",    to:"C",       color:GREEN },
  { from:"USB8",    to:"G",       color:GREEN },
  { from:"USB8",    to:"TADO",    color:GREEN },
  { from:"USB8",    to:"FIRE",    color:GREEN },
  { from:"USB8",    to:"GL1",     color:GREEN },
  { from:"USB8",    to:"GL2",     color:GREEN },
  { from:"USB8",    to:"GL3",     color:GREEN },
  { from:"W",       to:"WYZ",     color:GREEN },
  { from:"NS",      to:"D",       color:BLACK },
  { from:"MM",      to:"D",       color:BLACK },
  { from:"G",       to:"D",       color:BLACK },
  { from:"ZC",      to:"S",       color:BLACK },
  { from:"NAS",     to:"S",       color:BLACK },
  { from:"SI",      to:"S",       color:BLACK, dash:true },
  { from:"SC",      to:"S",       color:BLACK, dash:true },
  { from:"SW",      to:"S",       color:BLACK, dash:true },
  { from:"ZB",      to:"HUB24",   color:BLUE },
  { from:"HUB24",   to:"W",       color:BLUE },
  // NAS now on HUB24 not ZB
  { from:"HUB24",   to:"NAS",     color:BLUE },
  { from:"HUB24",   to:"MM",      color:BLUE },
  { from:"HUB24",   to:"S",       color:BLUE },
  { from:"HUB24",   to:"ZC",      color:BLUE },
  { from:"HUB24",   to:"HUE",     color:BLUE },
  { from:"HUB24",   to:"TADO",    color:BLUE },
  { from:"HUB24",   to:"RD",      color:BLUE },
  { from:"HUB24",   to:"SW",      color:BLUE },
  { from:"HUB24",   to:"SI",      color:BLUE },
  { from:"HUB24",   to:"SC",      color:BLUE },
  { from:"HUB24",   to:"GL1",     color:BLUE },
  { from:"HUB24",   to:"GL2",     color:BLUE },
  { from:"HUB24",   to:"GL3",     color:BLUE },
  { from:"HUB24",   to:"MLSTRIP", color:BLUE },
  { from:"RD",      to:"RDHUB",   color:BLUE },
  { from:"RDHUB",   to:"AMSDT",   color:BLUE },
  { from:"RDHUB",   to:"PRUSA",   color:BLUE },
  { from:"GL1",     to:"SI",      color:KVM },
  { from:"GL2",     to:"SC",      color:KVM },
  { from:"GL3",     to:"SW",      color:KVM },
];

const FILTERS = [
  { key:"AC",   label:"AC power", color:RED   },
  { key:"USB",  label:"USB",      color:GREEN },
  { key:"HDMI", label:"HDMI",     color:BLACK },
  { key:"ETH",  label:"Ethernet", color:BLUE  },
  { key:"KVM",  label:"KVM",      color:KVM   },
  { key:"SVC",  label:"Services", color:SVC   },
];

function ServiceLabel({ id, n, show }) {
  const svcs = services[id];
  if (!svcs || !show) return null;
  const lineH = 13;
  const boxH = svcs.length * lineH + 10;
  const boxW = 120;
  const bx = n.x - boxW / 2;
  const by = n.y + NH / 2 + 4;
  return (
    <g style={{ opacity: show ? 1 : 0, transition:"opacity 0.2s", pointerEvents:"none" }}>
      <rect x={bx} y={by} width={boxW} height={boxH} rx={3}
        fill="#E0F2F1" stroke="#00695C" strokeWidth={1}/>
      {svcs.map((s, i) => (
        <text key={i} x={n.x} y={by + 8 + i * lineH}
          textAnchor="middle" dominantBaseline="central"
          fontSize={8} fill="#00695C" fontStyle="italic">{s}</text>
      ))}
    </g>
  );
}

const hdmiInfo = {
  S: {
    title: "Samsung — HDMI inputs",
    rows: [
      { pos:"1", src:"Ziggo",    note:"" },
      { pos:"2", src:"SX group", note:"Any one of: IB, CWH, or WBU (selectable)" },
      { pos:"3", src:"—",        note:"empty" },
      { pos:"4", src:"—",        note:"empty" },
    ],
  },
  D: {
    title: "Dyon TV — HDMI inputs",
    rows: [
      { pos:"1", src:"NS (Switch)", note:"" },
      { pos:"2", src:"Google TV",   note:"" },
      { pos:"3", src:"Mac Mini",    note:"" },
    ],
  },
};

function TVPopup({ id, n, visible, onClose }) {
  const info = hdmiInfo[id];
  if (!info || !visible) return null;
  const pw = 280, ph = info.rows.length * 28 + 70;
  const px = Math.min(n.x - pw / 2, W - pw - 10);
  const py = n.y - ph - 12;
  return (
    <g style={{ pointerEvents:"all" }} onClick={e => { e.stopPropagation(); onClose(); }}>
      {/* shadow */}
      <rect x={px+3} y={py+3} width={pw} height={ph} rx={6} fill="#00000022"/>
      {/* box */}
      <rect x={px} y={py} width={pw} height={ph} rx={6}
        fill="#FFFDE7" stroke="#F9A825" strokeWidth={1.5}/>
      {/* title */}
      <text x={px+pw/2} y={py+18} textAnchor="middle" dominantBaseline="central"
        fontSize={11} fontWeight={700} fill="#333">{info.title}</text>
      {/* header row */}
      {["Pos","Source","Note"].map((h,i)=>(
        <text key={h} x={px+[14,70,160][i]} y={py+36}
          dominantBaseline="central" fontSize={9} fontWeight={700} fill="#555">{h}</text>
      ))}
      <line x1={px+8} y1={py+44} x2={px+pw-8} y2={py+44} stroke="#F9A825" strokeWidth={0.8}/>
      {/* data rows */}
      {info.rows.map((r,i)=>(
        <g key={i}>
          <rect x={px+8} y={py+47+i*28} width={pw-16} height={26} rx={3}
            fill={i%2===0?"#FFF9C4":"#FFFDE7"}/>
          <text x={px+14} y={py+60+i*28} dominantBaseline="central" fontSize={9} fill="#333">{r.pos}</text>
          <text x={px+70} y={py+60+i*28} dominantBaseline="central" fontSize={9} fontWeight={600} fill="#1565C0">{r.src}</text>
          <text x={px+160} y={py+60+i*28} dominantBaseline="central" fontSize={8} fill="#888" fontStyle="italic">{r.note}</text>
        </g>
      ))}
      {/* close hint */}
      <text x={px+pw-8} y={py+10} textAnchor="end" dominantBaseline="central"
        fontSize={9} fill="#aaa">click to close</text>
    </g>
  );
}

function NodeBox({ id, n, highlight, showSvc, onTVClick, tvOpen }) {
  const lines = n.label.split("\n");
  const cfg = {
    strip:  { bg:"#FFF3E0", border:"#E65100" },
    usb:    { bg:"#E8F5E9", border:"#1B5E20" },
    kvm:    { bg:"#F3E5F5", border:"#4A148C" },
    device: { bg:"#E3F2FD", border:"#0D47A1" },
  };
  const { bg, border } = cfg[n.type] || cfg.device;
  const isTV = (id === "S" || id === "D");
  const w = isTV ? NW + 10 : NW;
  const h = isTV ? NH + 6  : NH;
  return (
    <g style={{ opacity: highlight ? 1 : 0.12, transition:"opacity 0.2s",
      cursor: isTV ? "pointer" : "default" }}
      onClick={isTV ? (e)=>{ e.stopPropagation(); onTVClick(id); } : undefined}>
      <rect x={n.x-w/2} y={n.y-h/2} width={w} height={h}
        rx={5} fill={bg} stroke={isTV && tvOpen ? "#F9A825" : border}
        strokeWidth={isTV ? 2.5 : 1.5}/>
      {lines.map((l,i) => (
        <text key={i} x={n.x} y={n.y+(i-(lines.length-1)/2)*13}
          textAnchor="middle" dominantBaseline="central"
          fontSize={i===0?11:9} fontWeight={i===0?700:400} fill={border}>{l}</text>
      ))}
      <ServiceLabel id={id} n={n} show={showSvc && highlight}/>
      {isTV && <TVPopup id={id} n={n} visible={tvOpen} onClose={()=>onTVClick(null)}/>}
    </g>
  );
}

function Edge({ e, highlight }) {
  const a = nodes[e.from], b = nodes[e.to];
  if (!a || !b) return null;
  return (
    <line x1={a.x} y1={a.y} x2={b.x} y2={b.y}
      stroke={e.color} strokeWidth={highlight ? 2 : 1}
      strokeDasharray={e.dash ? "6 4" : "none"}
      opacity={highlight ? 0.78 : 0.05}
      style={{ transition:"opacity 0.2s" }}
      markerEnd={`url(#a${e.color.replace("#","")})`}/>
  );
}

export default function App() {
  const [active, setActive] = useState({AC:true,USB:true,HDMI:true,ETH:true,KVM:true,SVC:false});
  const [tvOpen, setTvOpen] = useState(null); // "S", "D", or null
  const toggle = k => setActive(a => ({...a,[k]:!a[k]}));
  const handleTVClick = id => setTvOpen(prev => prev === id ? null : id);

  const activeColors = new Set(FILTERS.filter(f=>active[f.key] && f.key!=="SVC").map(f=>f.color));
  const lit = new Set();
  edges.forEach(e => { if(activeColors.has(e.color)){ lit.add(e.from); lit.add(e.to); }});
  // When SVC is on, also light up nodes that have services
  if (active.SVC) Object.keys(services).forEach(id => lit.add(id));


  return (
    <div style={{fontFamily:"sans-serif",padding:12,background:"#f0f0f0",minHeight:"100vh"}}>
      <div style={{display:"flex",gap:10,flexWrap:"wrap",alignItems:"center",marginBottom:10}}>
        <b style={{fontSize:13,color:"#333"}}>Filter:</b>
        {FILTERS.map(f=>(
          <button key={f.key} onClick={()=>toggle(f.key)} style={{
            padding:"4px 14px", borderRadius:20, border:`2px solid ${f.color}`,
            background:active[f.key]?f.color:"transparent",
            color:active[f.key]?"#fff":f.color,
            fontWeight:700, fontSize:12, cursor:"pointer", transition:"all 0.15s"
          }}>{f.label}</button>
        ))}
        <span style={{marginLeft:"auto",fontSize:10,color:"#888"}}>Dashed = selectable HDMI · Click Samsung or Dyon TV for HDMI details</span>
      </div>

      <svg width="100%" viewBox={`0 0 ${W} ${H}`}
        style={{background:"#fff",border:"1px solid #ccc",borderRadius:8,display:"block"}}
        onClick={()=>setTvOpen(null)}>
        <defs>
          {[RED,GREEN,BLACK,BLUE,KVM].map(c=>(
            <marker key={c} id={`a${c.replace("#","")}`}
              viewBox="0 0 10 10" refX="8" refY="5" markerWidth="5" markerHeight="5" orient="auto-start-reverse">
              <path d="M2 1L8 5L2 9" fill="none" stroke={c} strokeWidth={1.5}
                strokeLinecap="round" strokeLinejoin="round"/>
            </marker>
          ))}
        </defs>

        {[
          [Y.y1, "↓ AC power"],
          [Y.y4, "⟵ TVs ⟶"],
          [Y.y5, "↑ HDMI sources"],
        ].map(([y,label])=>(
          <text key={y} x={W-20} y={y} textAnchor="end" dominantBaseline="central"
            fontSize={9} fill="#bbb" fontStyle="italic">{label}</text>
        ))}

        {edges.map((e,i)=><Edge key={i} e={e} highlight={activeColors.has(e.color)}/>)}
        {Object.entries(nodes).map(([id,n])=>(
          <NodeBox key={id} id={id} n={n} highlight={lit.has(id)} showSvc={active.SVC}
            onTVClick={handleTVClick} tvOpen={tvOpen===id}/>
        ))}

        {/* Legend */}
        <rect x={W-215} y={20} width={205} height={328} rx={6}
          fill="#fafafa" stroke="#ddd" strokeWidth={1}/>
        <text x={W-203} y={42} fontSize={11} fontWeight={700} fill="#444">Legend</text>
        {FILTERS.map((f,i)=>(
          <g key={f.key}>
            {f.key==="SVC"
              ? <rect x={W-203} y={66+i*28-6} width={34} height={12} rx={3} fill="#E0F2F1" stroke="#00695C" strokeWidth={1}/>
              : <line x1={W-203} y1={66+i*28} x2={W-169} y2={66+i*28}
                  stroke={f.color} strokeWidth={2.5}
                  strokeDasharray={f.key==="HDMI"?"6 4":"none"}/>
            }
            <text x={W-161} y={66+i*28} dominantBaseline="central" fontSize={10} fill="#333">{f.label}</text>
          </g>
        ))}
        <line x1={W-203} y1={240} x2={W-169} y2={240}
          stroke={BLACK} strokeWidth={1.5} strokeDasharray="6 4"/>
        <text x={W-161} y={240} dominantBaseline="central" fontSize={9} fill="#666">HDMI selectable</text>
        {[["#FFF3E0","#E65100","Power strip"],
          ["#E8F5E9","#1B5E20","USB hub"],
          ["#F3E5F5","#4A148C","GL-RM1 KVM"],
          ["#E3F2FD","#0D47A1","Device"]].map(([bg,border,lbl],i)=>(
          <g key={lbl}>
            <rect x={W-203} y={258+i*20} width={12} height={10} rx={2}
              fill={bg} stroke={border} strokeWidth={1.5}/>
            <text x={W-185} y={263+i*20} dominantBaseline="central" fontSize={10} fill="#555">{lbl}</text>
          </g>
        ))}
      </svg>
    </div>
  );
}
