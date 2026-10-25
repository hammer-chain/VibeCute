import AppKit

/// Local color/shape matching; no OCR, model calls, disk screenshots or network.
/// Work is bounded to 1280 x 800 pixels and the 32 largest orange components.
enum CrabIconDetector {
    struct Match { let rect: CGRect; let score: Double }
    static func detect(_ image: CGImage, allowedRegions:[CGRect]? = nil) -> Match? {
        let factor=min(1,min(1280.0/Double(image.width),800.0/Double(image.height)))
        let w=max(1,Int(Double(image.width)*factor)),h=max(1,Int(Double(image.height)*factor))
        guard let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let raw=c.data else {return nil}
        c.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
        let p=raw.assumingMemoryBound(to:UInt8.self)
        var mask=[UInt8](repeating:0,count:w*h)
        for i in 0..<w*h {let r=Int(p[i*4]),g=Int(p[i*4+1]),b=Int(p[i*4+2]);if r>115 && r-g>25 && g-b>6 && g>45 && r-b>45 {mask[i]=1}}
        var seen=[UInt8](repeating:0,count:w*h), candidates:[CGRect]=[]
        for start in mask.indices where mask[start]==1 && seen[start]==0 {
            var queue=[start],head=0,x0=start%w,x1=x0,y0=start/w,y1=y0
            seen[start]=1
            while head<queue.count {
                let v=queue[head];head+=1;let x=v%w,y=v/w
                x0=min(x0,x);x1=max(x1,x);y0=min(y0,y);y1=max(y1,y)
                for (dx,dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                    let nx=x+dx,ny=y+dy
                    if nx>=0 && nx<w && ny>=0 && ny<h {let n=ny*w+nx;if mask[n]==1 && seen[n]==0 {seen[n]=1;queue.append(n)}}
                }
            }
            let rw=x1-x0+1,rh=y1-y0+1
            if rw>=16 && rh>=10 && rw<=480 && rh<=320 && Double(rw)/Double(rh)>1.25 && Double(rw)/Double(rh)<2.2 && queue.count>rw*rh/3 {
                candidates.append(CGRect(x:x0,y:y0,width:rw,height:rh))
            }
        }
        var best:Match?
        for candidate in candidates.sorted(by:{$0.width*$0.height>$1.width*$1.height}).prefix(32) {
          // A touching hand or accent can join the top of the orange component.
          for trim in 0...10 {
            let cut=candidate.height*Double(trim)*0.02
            let rect=CGRect(x:candidate.minX,y:candidate.minY+cut,width:candidate.width,height:candidate.height-cut)
            let normalized=CGRect(x:rect.minX/Double(w),y:rect.minY/Double(h),width:rect.width/Double(w),height:rect.height/Double(h))
            if let allowedRegions,!allowedRegions.contains(where:{$0.contains(normalized)}) {continue}
            var correct=0,total=0,eyes=0
            for row in 0..<24 {for col in 0..<40 {
                let x=(Double(col)+0.5)/40,y=(Double(row)+0.5)/24
                let body=(x>=0.11 && x<=0.89 && y<0.8) || (y>=0.4 && y<=0.6)
                let leg=y>=0.8 && ((x>=0.11 && x<=0.17)||(x>=0.22 && x<=0.28)||(x>=0.72 && x<=0.78)||(x>=0.83 && x<=0.89))
                let eye=y>=0.2 && y<=0.4 && ((x>=0.22 && x<=0.28)||(x>=0.72 && x<=0.78))
                let expected=(body || leg) && !eye
                let px=min(w-1,Int(rect.minX+x*rect.width)),py=min(h-1,Int(rect.minY+y*rect.height))
                let actual=mask[py*w+px]==1
                if actual==expected {correct+=1};total+=1
                if eye && !actual {eyes+=1}
            }}
            let score=Double(correct)/Double(total)
            if score>=0.88 && eyes>=16 && score>(best?.score ?? 0) {
                best=Match(rect:CGRect(x:rect.minX/Double(w),y:rect.minY/Double(h),width:rect.width/Double(w),height:rect.height/Double(h)),score:score)
            }
        }
        }
        return best
    }
}
