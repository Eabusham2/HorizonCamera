import CoreImage
import Foundation

enum DualCaptureComposer {
    static func compose(back:CIImage,front:CIImage,layout:DualCaptureLayout,canvas:CGSize) -> CIImage {
        let rect=CGRect(origin:.zero,size:canvas), black=CIImage(color:.black).cropped(to:rect)
        switch layout {
        case .pictureInPicture:
            let base=aspectFill(back,rect:rect).applyingFilter("CISourceOverCompositing",parameters:[kCIInputBackgroundImageKey:black])
            let pipW=rect.width*0.30,pipH=rect.height*0.30
            let pipRect=CGRect(x:rect.maxX-pipW-rect.width*0.035,y:rect.maxY-pipH-rect.height*0.025,width:pipW,height:pipH)
            let pip=aspectFill(front,rect:pipRect)
            let shadow=CIImage(color:CIColor(red:0,green:0,blue:0,alpha:0.65)).cropped(to:pipRect.insetBy(dx:-4,dy:-4))
            return pip.applyingFilter("CISourceOverCompositing",parameters:[kCIInputBackgroundImageKey:shadow.applyingFilter("CISourceOverCompositing",parameters:[kCIInputBackgroundImageKey:base])]).cropped(to:rect)
        case .splitVertical:
            let left=CGRect(x:0,y:0,width:rect.width/2,height:rect.height),right=CGRect(x:rect.width/2,y:0,width:rect.width/2,height:rect.height)
            let a=aspectFill(back,rect:left).applyingFilter("CISourceOverCompositing",parameters:[kCIInputBackgroundImageKey:black])
            return aspectFill(front,rect:right).applyingFilter("CISourceOverCompositing",parameters:[kCIInputBackgroundImageKey:a]).cropped(to:rect)
        case .splitHorizontal:
            let bottom=CGRect(x:0,y:0,width:rect.width,height:rect.height/2),top=CGRect(x:0,y:rect.height/2,width:rect.width,height:rect.height/2)
            let a=aspectFill(back,rect:top).applyingFilter("CISourceOverCompositing",parameters:[kCIInputBackgroundImageKey:black])
            return aspectFill(front,rect:bottom).applyingFilter("CISourceOverCompositing",parameters:[kCIInputBackgroundImageKey:a]).cropped(to:rect)
        }
    }

    static func aspectFill(_ input:CIImage,rect:CGRect) -> CIImage {
        var image=input.transformed(by:CGAffineTransform(translationX:-input.extent.minX,y:-input.extent.minY))
        let scale=max(rect.width/image.extent.width,rect.height/image.extent.height)
        image=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        image=image.cropped(to:CGRect(x:image.extent.midX-rect.width/2,y:image.extent.midY-rect.height/2,width:rect.width,height:rect.height))
        return image.transformed(by:CGAffineTransform(translationX:rect.minX-image.extent.minX,y:rect.minY-image.extent.minY))
    }
}
