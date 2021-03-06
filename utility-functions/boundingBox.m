function bb = boundingBox(f)
% FORMAT [indx, indy, indz] = boundingBox(f)
% f    - 3D volume
% indx - Index range that covers all non-zero voxels in f
% indy - "   "
% indz - "   "
%
% Compute the index range (equivalent to a bounding box in voxels) that
% covers all non-zero voxels in an image.

    f = f ~= 0;
    f1 = any(any(f, 3), 2);
    xmin = find(f1, 1, 'first');
    xmax = find(f1, 1, 'last');
    f1 = any(any(f, 3), 1);
    ymin = find(f1, 1, 'first');
    ymax = find(f1, 1, 'last');
    f1 = any(any(f, 2), 1);
    zmin = find(f1, 1, 'first');
    zmax = find(f1, 1, 'last');
    clear f1 f
    bb.x = xmin:xmax;
    bb.y = ymin:ymax;
    bb.z = zmin:zmax;

end