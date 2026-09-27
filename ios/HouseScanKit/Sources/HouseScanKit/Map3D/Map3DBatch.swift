import Foundation

extension Map3D {
    /// One batch of ARKit updates that arrived together with a move of the meter's anchor
    /// (`frame`, from `MapFrame.following`; nil when the meter didn't move). The move goes first:
    /// ARKit places every anchor it sends in the corrected world, and a chunk drawn with the old
    /// frame would move a second time with the map. `Map3DSession` applies its batches through
    /// this.
    public mutating func apply(frame: MapFrame?, planes: [UUID: PlaneObservation?], chunks: [UUID: MeshChunk?]) {
        if let frame { reanchor(frame) }
        for (id, plane) in planes {
            if let plane { update(plane) } else { removePlane(id: id) }
        }
        for (id, chunk) in chunks {
            if let chunk { update(chunk) } else { removeMeshChunk(id: id) }
        }
    }
}
