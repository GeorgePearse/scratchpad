"""Builds a pad file that explains the RF-DETR paper (arXiv 2511.09554) as one large diagram.

It shows that a pad is just JSON: nodes, edges and ink. Generate it, then copy it into the app:

    python3 Examples/rfdetr_explainer.py pad.json 8300 7400
    xcrun devicectl device copy to --device <id> --domain-type appDataContainer \\
        --domain-identifier com.georgepearse.scratchpad \\
        --source pad.json --destination "Library/Application Support/pad.json"

The two numbers are where the top-left corner goes on the 20000-point canvas. An optional fourth
argument (s1 to s8) writes a single section. Quit the app before copying, or it will save over the file.
"""
import json, sys, textwrap
nodes=[]; edges=[]; sections={}; cur=[None]
def _add(n):
    nodes.append(n); sections.setdefault(cur[0],[]).append(n["id"]); return n["id"]
def box(x,y,w,h,label,color="default",shape="rect"):
    return _add({"id":f"b{len(nodes)}","shape":shape,"frame":[[x,y],[w,h]],"label":label,"color":color})
def text(x,y,lines,size=15,color="default"):
    if isinstance(lines,str): lines=[lines]
    lh=size/0.62; w=max(len(l) for l in lines)*size*0.56
    _add({"id":f"t{len(nodes)}","shape":"text","frame":[[x,y],[w,lh*len(lines)]],"label":"\n".join(lines),"color":color})
    return y+lh*len(lines)
def para(x,y,s,width=92,size=15,color="default",gap=14):
    return text(x,y,textwrap.wrap(s,width),size,color)+gap
def bullets(x,y,items,width=90,size=15):
    for it in items:
        ls=textwrap.wrap(it,width-2); ls=["•  "+ls[0]]+["    "+l for l in ls[1:]]
        y=text(x,y,ls,size)+8
    return y
def arrow(a,b,label="",style="arrow"):
    edges.append({"id":f"a{len(edges)}","from":a,"to":b,"label":label,"style":style})
def heading(x,y,s,key):
    cur[0]=key; return text(x,y,s,30)+10
def table(x,y,widths,rows,size=14,header_color="blue"):
    lh=size/0.62+6
    for r,row in enumerate(rows):
        cx=x
        for w,cell in zip(widths,row):
            if cell!="": text(cx,y,str(cell),size,header_color if r==0 else "default")
            cx+=w
        y+=lh
    return y+10

# ---------------- Title
cur[0]="title"
y=text(0,0,"RF-DETR",64)
y=text(0,y+4,"Neural Architecture Search for Real-Time Detection Transformers",26)
y=text(0,y+8,["Robinson, Robicheaux, Popov, Ramanan, Peri (Roboflow, Carnegie Mellon). arXiv 2511.09554, v2, Feb 2026.",
              "Architecture details the paper inherits from LW-DETR (arXiv 2406.03459) are marked [LW-DETR]."],15,"gray")
text(1750,20,["Pinch to zoom. Pan with two fingers",
              "(one finger if finger drawing is off).",
              "The arrows-in button fits everything."],15,"gray")

# ---------------- 1 The idea
y=heading(0,250,"1.  The idea in one picture","s1")
a=box(0,y+10,250,110,"LW-DETR\nViT encoder, C2f projector, 3-layer deformable decoder","gray")
b=box(330,y+10,250,110,"Swap the backbone\nCAEv2 → DINOv2 (internet-scale pretraining)","blue")
c=box(660,y+10,250,110,"Train once as a supernet\nweight-sharing NAS over 5 knobs","purple")
d=box(990,y+10,250,110,"Search, don't retrain\n6,468 sub-nets scored on validation","orange")
e=box(1320,y+10,250,110,"RF-DETR family\nN, S, M, L, XL, 2XL, Max on one Pareto curve","green","rounded")
for p,q in [(a,b),(b,c),(c,d),(d,e)]: arrow(p,q)
yy=para(0,y+150,"The paper's argument: specialist real-time detectors have been tuned so hard on COCO (bespoke architectures, learning-rate and augmentation schedules) that they transfer poorly to real datasets, while fine-tuned vision-language detectors transfer well but are far too slow. RF-DETR keeps a light DETR, gives it a foundation-model backbone, and replaces hand-designed model sizes with a search over one trained network.",118)
bullets(0,yy,["RF-DETR (nano): 48.0 AP on COCO at 2.3 ms on a T4, 5.3 AP above D-FINE (nano) at similar latency.",
              "RF-DETR (2x-large): 60.1 AP on COCO at 17.2 ms. The paper says it is the first real-time detector past 60 AP.",
              "On Roboflow100-VL (100 varied datasets), 2x-large beats fine-tuned GroundingDINO (tiny) by 1.2 AP at about a twentieth of the runtime."],118)

# ---------------- 2 Forward pass
y=heading(0,800,"2.  The forward pass  (the paper's Figure 2)","s2")
W,H,G=250,130,70; X=lambda i:i*(W+G); py=y+10
st=[("Image\nresolution r, one of the NAS knobs","gray","rounded"),
    ("Patchify\npatch size p, resized FlexiViT-style; position embeddings interpolated","blue","rect"),
    ("DINOv2 ViT, 12 layers\nwindowed and global attention interleaved","blue","rect"),
    ("Multi-scale projector\nC2f block [LW-DETR], with LayerNorm instead of BatchNorm","green","rect"),
    ("Query selection\ntop-K locations become object queries [LW-DETR]","orange","rect"),
    ("Decoder, up to 6 layers\nself-attention, deformable cross-attention, FFN","purple","rect"),
    ("Detection head\nclass scores and a box for every query. No NMS.","red","rounded")]
ids=[box(X(i),py,W,H,l,c,s) for i,(l,c,s) in enumerate(st)]
for p,q in zip(ids,ids[1:]): arrow(p,q)
pm=box(X(3)-40,py+250,W+80,120,"Pixel embedding map\nprojector output, bilinearly upsampled, then a light projector","green")
dot=box(X(5)-40,py+250,W+80,120,"Masks = query embeddings · pixel embeddings\none mask per query, at every decoder layer","red","rounded")
arrow(ids[3],pm,"RF-DETR-Seg","dashed"); arrow(ids[5],dot,"queries via FFN","dashed"); arrow(pm,dot,"","dashed")
ny=py+420
yy=text(0,ny,"Solid arrows: detection. Dashed arrows: the extra segmentation branch of RF-DETR-Seg.",15,"gray")
bullets(0,yy+10,["There is no separate transformer encoder after the backbone, as there is in RT-DETR. The ViT is the encoder [LW-DETR].",
               "The deformable cross-attention and the segmentation head both read the projector output by bilinear interpolation, so the two heads see features with the same spatial layout.",
               "The segmentation head deliberately uses one low-resolution map, not multi-scale backbone features as MaskDINO does, to keep latency down. The pixel embeddings can be read as segmentation prototypes, as in YOLACT.",
               "Detection and segmentation losses are applied at every decoder layer. That is what later allows layers to be dropped at inference."],112)
bullets(1250,yy+10,["Three things change relative to LW-DETR: the backbone (CAEv2 → DINOv2), the projector's normalisation (BatchNorm → LayerNorm, so training works with gradient accumulation on consumer GPUs), and the whole training recipe (section 6).",
               "DINOv2's encoder has 12 layers against 10 in LW-DETR's CAEv2 encoder, so the new backbone is slower. The paper buys the latency back with NAS (section 7).",
               "Everything else in the detector (projector design, query selection, decoder, Group DETR, losses) is LW-DETR's."],108)

# ---------------- 3 Backbone
y=heading(0,1750,"3.  Backbone: where attention is windowed","s3")
win={0,1,3,4,6,7,9,10}; ly=y+20; L=[]
for i in range(12):
    L.append(box(i*112,ly,92,92,f"{i}\n{'window' if i in win else 'global'}","blue" if i in win else "orange"))
for p,q in zip(L,L[1:]): arrow(p,q,"","line")
text(0,ly+105,"Blue: self-attention restricted to windows. Orange: global self-attention. RF-DETR windows layers {0, 1, 3, 4, 6, 7, 9, 10}.",15,"gray")
agg=box(980,ly+170,360,100,"Multi-level feature aggregation\nintermediate and final feature maps combined [LW-DETR]","green")
arrow(L[11],agg)
wy=ly+170
text(0,wy,"1 window",15); box(0,wy+30,150,150,"all tokens attend to each other","orange")
text(210,wy,"2 windows",15); box(210,wy+30,72,150,"","blue"); box(288,wy+30,72,150,"","blue")
text(420,wy,"4 windows",15)
for r in range(2):
    for c2 in range(2): box(420+c2*78,wy+30+r*78,72,72,"","blue")
text(620,wy+50,["Each window attends only",
                "within itself. Cost falls",
                "from N² to N²/windows."],15,"gray")
yy=bullets(0,wy+215,[
 "Global self-attention is quadratic in the number of tokens, which is what makes a plain ViT expensive at detection resolutions. Windowed layers split the feature map into non-overlapping windows and attend inside each [LW-DETR].",
 "Feature maps are stored window by window (\"window-major\"), so switching between windowed and global layers needs no costly permutation [LW-DETR].",
 "RF-DETR and LW-DETR have the same number of windowed layers, but RF-DETR makes them contiguous pairs (LW-DETR uses {0, 1, 3, 6, 7, 9}). Contiguous windowed blocks skip a reshape, so it runs slightly faster.",
 "DINOv2 relies on a class token, which CAEv2 does not have. RF-DETR duplicates the class token once per window; in global layers the copies attend to each other. Extra windows therefore cost extra tokens, which is why the search usually settles on 2 windows where LW-DETR preferred 4.",
 "The number of windows per block is a NAS knob: 1, 2 or 4.",
 "Backbone choice (ablation, all on the LW-DETR-M recipe): DINOv2 ViT-S/14 54.3 AP against CAEv2 ViT-S/16 52.3 AP. SAM2's Hiera-S and SigLIPv2 were slower or worse under FP16."],104)

# ---------------- 4 Projector + queries
x0=1750
y=heading(x0,1750,"4.  From tokens to object queries","s4")
W4,H4,G4=215,120,45; qy=y+20
q=[("Aggregated ViT features\nseveral layers, one grid","blue"),
   ("C2f projector\nconv block from YOLOv8; LayerNorm in RF-DETR","green"),
   ("Feature map\n1/p of the input size, 256 channels [LW-DETR]","green"),
   ("Score every location\na class logit and a box per position","orange"),
   ("Keep the top K\n300 in training","orange"),
   ("Object queries\ncontent + spatial","purple")]
Q=[box(x0+i*(W4+G4),qy,W4,H4,l,c) for i,(l,c) in enumerate(q)]
for p,r in zip(Q,Q[1:]): arrow(p,r)
ce=box(x0+5*(W4+G4),qy+200,W4,100,"Learned content embeddings","gray","rounded"); arrow(ce,Q[5])
yy=bullets(x0,qy+160,[
 "The projector is the only neck. For LW-DETR's tiny to medium models it outputs a single scale at stride 16; the large and xlarge models add a 1/8 and a 1/32 map through a deconvolution and a strided convolution, with a multi-scale decoder [LW-DETR].",
 "Query selection is the \"two-stage\" trick from Deformable DETR, in the mixed form of DINO: the spatial part of each query is the embedding of a box predicted at one of the K best-scoring locations, and the content part is a learned embedding [LW-DETR].",
 "So the decoder starts from K boxes that already sit near real objects, which is why few decoder layers are enough.",
 "RF-DETR adds a twist at inference. Queries are ordered by the maximum sigmoid class logit of their encoder token, and the least confident can simply be dropped (50, 100, 200 or 300 kept) with no retraining.",
 "Dropping the 100 lowest-confidence queries of the nano model costs almost no accuracy. The best query count tracks how many objects a dataset has per image: RF100-VL models keep fewer than COCO models."],84)

# ---------------- 5 Decoder
y=heading(0,2850,"5.  One decoder layer, and the heads","s5")
dx=40; dy=y+20; DW=360
d0=box(dx,dy,DW,80,"K object queries + reference boxes","purple","rounded")
d1=box(dx,dy+130,DW,90,"Self-attention\nqueries talk to each other (suppresses duplicates)","purple")
d2=box(dx,dy+270,DW,110,"Deformable cross-attention\nsample the feature map at a few points around each reference box","purple")
d3=box(dx,dy+430,DW,70,"Feed-forward network","purple")
d4=box(dx,dy+550,DW,80,"Refined queries + refined boxes","purple","rounded")
for p,r in [(d0,d1),(d1,d2),(d2,d3),(d3,d4)]: arrow(p,r)
fm=box(dx+480,dy+280,230,90,"Projector feature map","green"); arrow(fm,d2,"bilinear samples")
h1=box(dx-40,dy+700,200,90,"Class head\nlinear layer","red"); h2=box(dx+190,dy+700,200,90,"Box head\nsmall MLP","red"); h3=box(dx+420,dy+700,230,90,"Mask embedding\nFFN, Seg only","red")
for h in (h1,h2,h3): arrow(d4,h)
text(dx+480,dy+440,["Repeat for L layers.","Each layer's output goes","through the heads and","gets its own loss."],15,"gray")
yy=bullets(820,dy,[
 "Deformable attention is what keeps the decoder cheap: instead of attending to every token of the feature map, each query reads a small fixed number of sampled points [LW-DETR, after Deformable DETR].",
 "LW-DETR uses 3 decoder layers where classic DETRs use 6, halving decoder time. RF-DETR trains with 6 and chooses the depth afterwards.",
 "Because every layer is supervised on its own, any suffix of the decoder can be removed at inference. Removing the last layer of the nano model cuts latency by about 10% for about 2 AP.",
 "Removing all of them still works: the output is then the query-selection proposals themselves, with no cross-attention and no query self-attention. The paper notes this is effectively a single-stage, YOLO-like detector without NMS.",
 "Truncating the decoder also shrinks the segmentation branch, since masks are computed per decoder layer.",
 "Found by the search: detection models end up with a wide, shallow decoder (300 queries, 2 to 5 layers). Segmentation models end up thin and deep (100 to 300 queries, 4 to 6 layers), which the paper reads as a minimum useful depth for the mask head."],96)

# ---------------- 6 Training
y=heading(x0,2850,"6.  Training","s6")
ty=y+20
t1=box(x0,ty,250,110,"Outputs of every decoder layer","purple")
t2=box(x0+330,ty,250,110,"Hungarian matching\none query per ground-truth box","red")
t3=box(x0+660,ty,300,110,"Loss\nIA-BCE + 2 · GIoU + 5 · L1 [LW-DETR]","red")
t4=box(x0+330,ty+190,250,110,"Group DETR\n13 query groups share the decoder, training only [LW-DETR]","orange")
arrow(t1,t2); arrow(t2,t3); arrow(t4,t2)
yy=text(x0+1010,ty,["IoU-aware classification [LW-DETR]:",
                    "the target for a matched query is",
                    "t = s^0.25 · IoU^0.75, so the score",
                    "also says how good the box is."],15,"gray")
yy=bullets(x0,ty+340,[
 "One-to-one matching is what removes NMS: each object is claimed by exactly one query, so duplicates are trained away instead of filtered afterwards.",
 "Group DETR gives each image 13 times as many positive matches during training and costs nothing at inference, where only the primary group runs [LW-DETR].",
 "Pretraining: Objects-365, pseudo-labelled with SAM2 masks so the detection and segmentation heads pretrain on the same data.",
 "\"Gentler\" optimisation to protect DINOv2's features: learning rate 1e-4 (LW-DETR uses 4e-4), batch size 128, gradients clipped at 0.1, a per-layer learning-rate decay of 0.8 towards the early backbone layers, EMA weights, and no warm-up.",
 "Scheduler-free: cosine schedules assume a known training length, which does not hold across 100 different datasets.",
 "Augmentation is only horizontal flip and random crop. Heavier recipes bake in assumptions; a vertical flip teaches a driving model to detect reflections in puddles.",
 "Images are resized per batch, not per image as in LW-DETR, which avoids padding most images and makes every resolution equally likely during training. Scales run from 0.5 to 1.5 of the default.",
 "Training takes roughly 2 to 4 times as long as a non-NAS baseline, but it yields every model size at once."],98)

# ---------------- 7 NAS
y=heading(0,4050,"7.  Weight-sharing NAS: one training run, thousands of models","s7")
ky=y+20; KW=290
kn=[("Patch size\n8, 10, 12, 16, 20, 24, 32\n(14 also evaluated, unseen in training)","blue"),
    ("Image resolution\n320 to 960 in steps of 64","blue"),
    ("Windows per block\n1, 2, 4","blue"),
    ("Decoder layers\ntrained with 6; 0 to 6 at inference","purple"),
    ("Queries\ntrained with 300; 50, 100, 200, 300 at inference","purple")]
K=[box(i*(KW+30),ky,KW,130,l,c) for i,(l,c) in enumerate(kn)]
s1=box(330,ky+230,600,110,"Every training step: sample one configuration uniformly,\ntake one gradient step on the shared weights","orange")
for k in K: arrow(k,s1,"","line")
s2=box(330,ky+420,600,90,"One fully trained supernet","gray","rounded")
s3=box(1010,ky+420,560,90,"Grid search on validation: 11 × 7 × 7 × 3 × 4 = 6,468 configurations","orange")
s4=box(1010,ky+230,560,110,"Accuracy-latency Pareto front\npick the point that fits the latency budget","green","rounded")
arrow(s1,s2); arrow(s2,s3); arrow(s3,s4)
yy=bullets(0,ky+560,[
 "The first three knobs change the encoder and must be sampled during training. The last two are applied only at inference: the model always trains with 6 layers and 300 queries.",
 "Nothing is searched until the base model has finished training on the target dataset, so every sub-net is already good and none needs fine-tuning. Fine-tuning a mined model adds little on COCO and a little more on RF100-VL.",
 "Sampling architectures acts as a regulariser, like dropout over networks (\"architecture augmentation\"). Adding NAS raised the base configuration from 54.3 to 54.6 AP even though its own patch size, 14, was never sampled.",
 "Sub-nets never seen in training sit on the same curve as seen ones.",
 "What matters is the number of spatial locations, resolution divided by patch size. Trading one for the other at a fixed token count gives nearly identical detection results. Not so for segmentation, whose mask features are tied to input resolution.",
 "The search itself is the expensive part: about 10,000 GPU-hours (200 T4s for 48 hours) for COCO."],118)
yy=text(0,yy+20,"Pareto-optimal detection models on COCO (the paper's Table 7)",18)
yy=table(0,yy+10,[90,150,140,130,190,130,160],[
 ["Size","Resolution","Patch","Windows","Decoder layers","Queries","Backbone"],
 ["N",384,16,2,2,300,"DINOv2-S"],["S",512,16,2,3,300,"DINOv2-S"],["M",576,16,2,4,300,"DINOv2-S"],
 ["L",704,16,2,4,300,"DINOv2-S"],["XL",700,20,1,5,300,"DINOv2-B"],["2XL",880,20,2,5,300,"DINOv2-B"],["Max",828,12,1,6,300,"DINOv2-B"]])
para(0,yy+4,"Within a backbone the search keeps patch size fixed (16 for DINOv2-S, 20 for DINOv2-B, 12 for segmentation) and scales resolution and decoder depth together. Segmentation models (Table 8) run from 312 px with 100 queries and 4 layers (N) to 890 px with 300 queries and 6 layers (Max), all on DINOv2-S.",118)

# ---------------- 8 Results
y=heading(x0,4050,"8.  Results, and how latency is measured","s8")
yy=text(x0,y+10,"COCO detection, T4 GPU, TensorRT FP16 (Table 2)",18)
yy=table(x0,yy+10,[230,80,120,120,140,90],[
 ["Model","Size","Params","GFLOPs","Latency ms","AP"],
 ["YOLOv11","N","2.6M",6.5,2.2,37.1],["D-FINE","N","3.8M",7.3,2.1,42.7],["LW-DETR","T","12.1M",21.4,1.9,42.9],["RF-DETR","N","30.5M",31.9,2.3,48.0],
 ["YOLOv11","S","9.4M",21.5,3.2,44.1],["D-FINE","S","10.2M",25.2,3.5,50.6],["RF-DETR","S","32.1M",59.8,3.5,52.9],
 ["YOLOv11","M","20.1M",68.0,5.1,48.3],["LW-DETR","M","28.2M",83.9,4.4,52.6],["D-FINE","M","19.2M",56.6,5.4,55.0],["RF-DETR","M","33.7M",78.8,4.4,54.7],
 ["RF-DETR","2XL","126.9M",438.4,17.2,60.1],["GroundingDINO","T","173.0M",1008.3,"427.6 (PyTorch)",58.2]])
yy=bullets(x0,yy,["RF-DETR is not small in parameters (about 30M even at nano); it is fast. Parameter count and latency are only loosely related, which is why sizes are bucketed by latency.",
                  "At medium, D-FINE is 0.3 AP ahead but a millisecond slower.",
                  "Segmentation: RF-DETR-Seg (nano) reaches 40.3 mask AP at 3.4 ms, above every YOLOv8 and YOLOv11 segmentation size. 2XL reaches 49.9.",
                  "RF100-VL: 2XL scores 63.5 AP with fine-tuning at 15.6 ms; fine-tuned GroundingDINO (tiny) scores 62.3 at about 310 ms. YOLOv8 and YOLOv11 do not improve with size on this benchmark."],96)
yy=text(x0,yy+16,"From LW-DETR (M) to RF-DETR (M), one change at a time (Table 5)",18)
yy=table(x0,yy+10,[430,110,120],[
 ["Change","AP","Latency ms"],
 ["LW-DETR (M)",52.6,4.4],["+ gentler hyperparameters, LayerNorm",51.6,4.4],["+ DINOv2 backbone",53.6,4.7],["+ more Objects-365 pretraining",54.3,4.7],
 ["+ weight-sharing NAS",54.6,4.7],["patch 14 → 16, resolution 560 → 640",54.4,4.7],["resolution 640 → 576",53.6,4.0],["windows per block 4 → 2",54.3,4.3],["decoder layers 3 → 4",54.6,4.4]])
bullets(x0,yy,["Benchmarking: published latencies disagree by 25% or more for the same model. The paper traces this to GPU power throttling and fixes it by pausing 200 ms between forward passes.",
               "Accuracy and latency must come from the same artifact. Several models are reported with FP16 speed and FP32 accuracy; naively quantised to FP16, D-FINE drops to 0.5 AP until its export is fixed.",
               "YOLO latencies usually omit NMS, and YOLO segmentation latencies stop at prototypes, not per-object masks. The paper's numbers include both."],96)

# ---------------- write
ox,oy=float(sys.argv[2]),float(sys.argv[3])
only=sys.argv[4] if len(sys.argv)>4 else None
keep=set(sections[only]) if only else None
out=[]
for n in nodes:
    if keep is not None and n["id"] not in keep: continue
    n=dict(n); n["frame"]=[[n["frame"][0][0]+ox,n["frame"][0][1]+oy],n["frame"][1]]; out.append(n)
ids={n["id"] for n in out}
json.dump({"diagram":{"nodes":out,"edges":[e for e in edges if e["from"] in ids and e["to"] in ids]},"drawing":"","version":2},open(sys.argv[1],"w"))
xs=[n["frame"][0][0]+n["frame"][1][0] for n in nodes]; ys=[n["frame"][0][1]+n["frame"][1][1] for n in nodes]
print(len(out),"nodes; full extent",int(max(xs)),"x",int(max(ys)))
