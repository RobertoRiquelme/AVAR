//
//  DiagramSceneBuilder.swift
//  AVAR2
//
//  Dedicated helper that builds the static scene graph entities for a diagram.
//

import Foundation
import RealityKit
import SwiftUI
import simd
import OSLog

#if os(visionOS)

@MainActor
struct DiagramSceneBuilder {
    struct BuildResult {
        let container: Entity
        let background: Entity
        let grabHandle: Entity
        let zoomHandle: Entity
        let rotationButton: Entity?
    }

    let filename: String?
    let isGraph2D: Bool
    let spawnScale: Float
    let appModel: AppModel?
    let logger: Logger?
    /// Shared position from collaborative session (overrides getNextDiagramPosition)
    let sharedPosition: SIMD3<Float>?
    /// Shared orientation from collaborative session
    let sharedOrientation: simd_quatf?
    /// Shared scale from collaborative session (overrides spawnScale)
    let sharedScale: Float?

    func buildScene(in content: RealityViewContent,
                    normalizationContext: NormalizationContext,
                    onClose: (() -> Void)?) -> BuildResult {
        let container = createRootContainer(in: content, normalizationContext: normalizationContext)
        let background = createBackgroundEntity(container: container, normalizationContext: normalizationContext)

        var rotationButton: Entity? = nil
        if let handles = setupUIControls(background: background,
                                         normalizationContext: normalizationContext,
                                         onClose: onClose) {
            rotationButton = handles.rotationButton
            return BuildResult(container: container,
                               background: background,
                               grabHandle: handles.grabHandle,
                               zoomHandle: handles.zoomHandle,
                               rotationButton: rotationButton)
        }

        let grabHandle = Entity()
        grabHandle.name = "grabHandle"
        let zoomHandle = Entity()
        zoomHandle.name = "zoomHandle"
        return BuildResult(container: container,
                           background: background,
                           grabHandle: grabHandle,
                           zoomHandle: zoomHandle,
                           rotationButton: rotationButton)
    }

    // MARK: - Scene construction

    private func createRootContainer(in content: RealityViewContent,
                                     normalizationContext: NormalizationContext) -> Entity {
        // Use shared position from collaborative session if available, otherwise get next position
        let pivot: SIMD3<Float>
        if let shared = sharedPosition {
            pivot = shared
            logger?.debug("📍 Using shared position from host: \(pivot)")
        } else {
            pivot = appModel?.getNextDiagramPosition(for: filename ?? "unknown") ?? SIMD3<Float>(0, 1.0, -2.0)
            logger?.debug("📍 Loading diagram at position: \(pivot)")
        }
        logger?.debug("📍 Available surfaces: \(appModel?.surfaceDetector.surfaceAnchors.count ?? 0)")

        let container = Entity()
        container.name = "graphRoot"
        container.position = pivot

        // Use shared scale if available, otherwise use spawn scale
        let scale = sharedScale ?? spawnScale
        container.scale = SIMD3<Float>(repeating: scale)

        // Apply shared orientation if available
        if let orientation = sharedOrientation {
            container.orientation = orientation
            logger?.debug("📍 Applied shared orientation from host")
        }

        content.add(container)
        return container
    }

    private func createBackgroundEntity(container: Entity,
                                        normalizationContext: NormalizationContext) -> Entity {
        let (bgWidth, bgHeight, bgDepth) = backgroundDimensions(from: normalizationContext)

        let background = Entity()
        background.name = "graphBackground"
        let bgShape = ShapeResource.generateBox(size: [bgWidth, bgHeight, bgDepth])
        background.components.set(CollisionComponent(shapes: [bgShape]))
        background.position = .zero
        container.addChild(background)

        return background
    }

    private func setupUIControls(background: Entity,
                                 normalizationContext: NormalizationContext,
                                 onClose: (() -> Void)?) -> (grabHandle: Entity, zoomHandle: Entity, rotationButton: Entity?)? {
        let (bgWidth, bgHeight, bgDepth) = backgroundDimensions(from: normalizationContext)

        if let onClose = onClose {
            let closeButton = createCloseButton(bgWidth: bgWidth, bgHeight: bgHeight, bgDepth: bgDepth, onClose: onClose)
            background.addChild(closeButton)
        }

        let grabHandle = createGrabHandle(bgWidth: bgWidth, bgHeight: bgHeight, bgDepth: bgDepth)
        background.addChild(grabHandle)
        logger?.debug("🎯 Grab handle entity set: \(grabHandle.name)")

        let zoomHandleResult = createZoomHandle(bgWidth: bgWidth, bgHeight: bgHeight, bgDepth: bgDepth)
        background.addChild(zoomHandleResult.zoomHandle)
        logger?.debug("🔍 Zoom handle entity set: \(zoomHandleResult.zoomHandle.name)")

        return (grabHandle: grabHandle, zoomHandle: zoomHandleResult.zoomHandle, rotationButton: zoomHandleResult.rotationButton)
    }

    // MARK: - Individual UI components

    private func createCloseButton(bgWidth: Float, bgHeight: Float, bgDepth: Float, onClose: @escaping () -> Void) -> Entity {
        let buttonContainer = Entity()
        buttonContainer.name = "closeButton"

        let buttonRadius: Float = Constants.CloseButton.radius
        let buttonThickness: Float = Constants.CloseButton.thickness
        let buttonMesh = MeshResource.generateCylinder(height: buttonThickness, radius: buttonRadius)
        let buttonMaterial = SimpleMaterial(color: .white.withAlphaComponent(0.8), isMetallic: false)
        let buttonEntity = ModelEntity(mesh: buttonMesh, materials: [buttonMaterial])
        buttonEntity.transform.rotation = simd_quatf(angle: .pi/2, axis: [1, 0, 0])
        buttonContainer.addChild(buttonEntity)

        let textMesh = MeshResource.generateText(
            "×",
            extrusionDepth: 0.002,
            font: .systemFont(ofSize: 0.06),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )
        let textMaterial = SimpleMaterial(color: .black.withAlphaComponent(0.7), isMetallic: false)
        let textEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])

        let textBounds = textMesh.bounds
        let textOffset = SIMD3<Float>(-textBounds.center.x, -textBounds.center.y, buttonThickness / 2 + 0.001)
        textEntity.position = textOffset
        buttonContainer.addChild(textEntity)

        positionCloseButton(buttonContainer, bgWidth: bgWidth, bgHeight: bgHeight, bgDepth: bgDepth, buttonRadius: buttonRadius)
        setupButtonInteraction(buttonContainer)

        return buttonContainer
    }

    private func positionCloseButton(_ buttonContainer: Entity, bgWidth: Float, bgHeight: Float, bgDepth: Float, buttonRadius: Float) {
        let halfH = bgHeight / 2
        let handleWidth: Float = bgWidth * Constants.GrabHandle.widthMultiplier
        let handleHeight: Float = Constants.GrabHandle.height
        let handleMargin: Float = Constants.GrabHandle.margin
        let handlePosY = -halfH - handleHeight / 2 - handleMargin
        let spacing: Float = Constants.CloseButton.spacing
        let closePosX = -handleWidth / 2 - buttonRadius - spacing
        let closePosZ = isGraph2D ? Float(0.01) : (bgDepth / 2 + 0.01)
        buttonContainer.position = [closePosX, handlePosY, closePosZ]
    }

    private func createGrabHandle(bgWidth: Float, bgHeight: Float, bgDepth: Float) -> Entity {
        let halfH = bgHeight / 2
        let handleWidth: Float = bgWidth * Constants.GrabHandle.widthMultiplier
        let handleHeight: Float = Constants.GrabHandle.height
        let handleThickness: Float = Constants.GrabHandle.thickness
        let handleMargin: Float = Constants.GrabHandle.margin
        let handleContainer = Entity()
        handleContainer.name = "grabHandle"

        let handleMesh = MeshResource.generateBox(size: [handleWidth, handleHeight, handleThickness], cornerRadius: handleHeight * Constants.GrabHandle.cornerRadiusMultiplier)
        let handleMaterial = SimpleMaterial(color: .white.withAlphaComponent(0.7), isMetallic: false)
        let handleEntity = ModelEntity(mesh: handleMesh, materials: [handleMaterial])
        handleContainer.addChild(handleEntity)

        let handlePosZ = isGraph2D ? Float(0.01) : (bgDepth / 2 + 0.01)
        handleContainer.position = [0, -halfH - handleHeight / 1 - handleMargin, handlePosZ]

        setupButtonInteraction(handleContainer)

        return handleContainer
    }

    private func setupButtonInteraction(_ buttonContainer: Entity) {
        let hoverEffectComponent = HoverEffectComponent()
        buttonContainer.generateCollisionShapes(recursive: true)
        buttonContainer.components.set(InputTargetComponent())
        buttonContainer.components.set(hoverEffectComponent)
        for child in buttonContainer.children {
            child.components.set(InputTargetComponent())
            child.components.set(hoverEffectComponent)
        }
    }

    private func createZoomHandle(bgWidth: Float, bgHeight: Float, bgDepth: Float) -> (zoomHandle: Entity, rotationButton: Entity?) {
        let zoomHandleContainer = Entity()
        zoomHandleContainer.name = "zoomHandle"

        // Native visionOS zoom handle dimensions - wider for better usability
        let handleThickness: Float = Constants.ZoomHandle.thickness
        let handleLength: Float = Constants.ZoomHandle.length
        let handleWidth: Float = Constants.ZoomHandle.width
        let cornerRadius: Float = handleWidth * Constants.ZoomHandle.cornerRadiusMultiplier

        let horizontalMesh = MeshResource.generateBox(size: [handleLength, handleWidth, handleThickness], cornerRadius: cornerRadius)
        let horizontalMaterial = SimpleMaterial(color: .white.withAlphaComponent(0.7), isMetallic: false)
        let horizontalEntity = ModelEntity(mesh: horizontalMesh, materials: [horizontalMaterial])
        horizontalEntity.name = "zoomHandleHorizontal"

        let verticalMesh = MeshResource.generateBox(size: [handleWidth, handleLength, handleThickness], cornerRadius: cornerRadius)
        let verticalMaterial = SimpleMaterial(color: .white.withAlphaComponent(0.7), isMetallic: false)
        let verticalEntity = ModelEntity(mesh: verticalMesh, materials: [verticalMaterial])
        verticalEntity.name = "zoomHandleVertical"

        verticalEntity.position = [handleLength/2 - handleWidth/2, 0, 0]
        horizontalEntity.position = [0, -handleLength/2 + handleWidth/2, 0]

        zoomHandleContainer.addChild(horizontalEntity)
        zoomHandleContainer.addChild(verticalEntity)

        var rotationButton: Entity? = nil
        if !isGraph2D {
            rotationButton = createRotationButton(handleWidth: handleWidth,
                                                  handleLength: handleLength,
                                                  handleThickness: handleThickness)
            if let rotationButton {
                zoomHandleContainer.addChild(rotationButton)
            }
        }

        let halfW = bgWidth / 2
        let halfH = bgHeight / 2
        let margin: Float = Constants.ZoomHandle.margin
        let zoomPosZ = isGraph2D ? Float(0.01) : (bgDepth / 2 + 0.01)
        zoomHandleContainer.position = [halfW - margin, -halfH + margin, zoomPosZ]

        zoomHandleContainer.generateCollisionShapes(recursive: true)
        zoomHandleContainer.components.set(InputTargetComponent())
        let hoverEffectComponent = HoverEffectComponent()
        zoomHandleContainer.components.set(hoverEffectComponent)

        for child in zoomHandleContainer.children {
            child.components.set(InputTargetComponent())
            child.components.set(hoverEffectComponent)
        }

        return (zoomHandle: zoomHandleContainer, rotationButton: rotationButton)
    }

    private func createRotationButton(handleWidth: Float, handleLength: Float, handleThickness: Float) -> Entity {
        let rotationButtonContainer = Entity()
        rotationButtonContainer.name = "rotationButton"

        let buttonRadius: Float = handleWidth * 0.8
        let buttonThickness: Float = handleThickness * 1.5
        let buttonMesh = MeshResource.generateCylinder(height: buttonThickness, radius: buttonRadius)

        let buttonMaterial = SimpleMaterial(color: .systemBlue.withAlphaComponent(0.8), isMetallic: false)
        let buttonEntity = ModelEntity(mesh: buttonMesh, materials: [buttonMaterial])
        buttonEntity.name = "rotationButtonCylinder"

        buttonEntity.transform.rotation = simd_quatf(angle: .pi/2, axis: [1, 0, 0])
        rotationButtonContainer.addChild(buttonEntity)

        let buttonX = handleLength/2 - handleWidth/2 - buttonRadius * 2 - 0.025
        let buttonY = -handleLength/2 + handleWidth/2 + buttonRadius + 0.03
        let buttonZ = buttonThickness/2 + handleThickness/2 - 0.01

        rotationButtonContainer.position = [buttonX, buttonY, buttonZ]

        rotationButtonContainer.generateCollisionShapes(recursive: true)
        rotationButtonContainer.components.set(InputTargetComponent())
        let hoverEffectComponent = HoverEffectComponent()
        rotationButtonContainer.components.set(hoverEffectComponent)

        for child in rotationButtonContainer.children {
            child.components.set(InputTargetComponent())
            child.components.set(hoverEffectComponent)
        }

        return rotationButtonContainer
    }

    // MARK: - Helpers

    private func backgroundDimensions(from normalizationContext: NormalizationContext) -> (Float, Float, Float) {
        let bgWidth = Float(normalizationContext.positionRanges[0] / normalizationContext.globalRange * 2)
        let bgHeight = Float(normalizationContext.positionRanges[1] / normalizationContext.globalRange * 2)
        let bgDepth = normalizationContext.positionCenters.count > 2 ?
            Float(normalizationContext.positionRanges[2] / normalizationContext.globalRange * 2) : 0.01
        return (bgWidth, bgHeight, bgDepth)
    }
}

#endif
