function [pf, c, bb] = pushImage(ipsi, f, varargin)
% _________________________________________________________________________
%
% Push the image to template space
%
% -------------------------------------------------------------------------
%
% FORMAT ([pf, (c), (bb)]) = pushImage(ipsi, f, (lat), ...)
%
% REQUIRED
% --------
% ipsi - Inverse transform (warps mu to f).
% f    - Observed image.
%
% OPTIONAL
% --------
% lat  - Output lattice [same as input]
%
% KEYWORD ARGUMENTS
% -----------------
% circ   - Circulant boundary conditions [true]
% loop   - How to split processing ('none', 'component') [auto]
% par    - If true, parallelise processing over classes/modalities [false]
% output - Cell of file_array to use as output [return numeric array]
% debug  - Print debugging info [false]
%
% OUTPUT
% ------
% pf   - Pushed image in template space 
% c    - Pushed voxel count
% bb   - Bounding box: correspondance between lat indices and the saved
%        volume
%
% -------------------------------------------------------------------------
% - Interpolation is trilinear.
% - Boundary conditions are circulant.
% _________________________________________________________________________

    % --- Parse inputs
    p = inputParser;
    p.FunctionName = 'pushImage';
    p.addRequired('ipsi', @checkarray);
    p.addRequired('f',    @checkarray);
    p.addOptional('lat',       [],     @(X) isnumeric(X) && length(X) >= 3);
    p.addParameter('circ',      1);
    p.addParameter('loop',     '',     @(X) ischar(X) && any(strcmpi(X, {'component', 'slice', 'none', ''})));
    p.addParameter('par',      false,  @isscalar);
    p.addParameter('output', []);
    p.addParameter('debug',  false);
    p.parse(ipsi, f, varargin{:});
    lat    = p.Results.lat;
    circ   = p.Results.circ;
    loop   = p.Results.loop;
    par    = p.Results.par;
    output = p.Results.output;
    debug  = p.Results.debug;
    
    if debug, fprintf('* pushImage\n'); end
    
    % --- Optimise parallelisation and splitting schemes
    if strcmpi(loop, 'slice')
        loop = '';
    end
    [par, loop] = autoParLoop(par, loop, isa(f, 'file_array'), 1, size(f,4));
    
    if circ(1)
        push = 'pushc';
    else
        push = 'push';
    end
    
    % -- Read dim info
    dim = [size(ipsi) 1 1];
    nc  = size(f,4);
    
    % --- Default argument
    if isempty(lat)
        lat = dim(1:3);
    end
    lat = lat(1:3);
    
    % --- Allocate output
    if ~iscell(output)
        output = {output};
    end
    if numel(output) < 2
        output = [output {[]}];
    end
    
    % --- Case where the input and output are the same file_array
    same_in_out = false;
    if isa(f, 'file_array') ...
            && ~isempty(output{1}) ...
            && isa(output{1}, 'file_array') ...
            && strcmpi({f.fname}, {output{1}.fname})
        % copy input
        same_in_out = true;
        pf = output{1};
        fnames = {pf.fname};
        [path, fname, ext] = fileparts(fnames{1});
        f.fname = fullfile(path, [fname '_copy' ext]);
        for k=1:size(pf, 4)
            f(:,:,:,k,:) = pf(:,:,:,k,:);
        end
    end
        
    
    ipsi = single(numeric(ipsi));
    
    % --- No loop
    if strcmpi(loop, 'none')
        if debug, fprintf('   - No loop\n'); end
        [pf1, c1] = spm_diffeo(push, single(numeric(f)), ipsi, lat);
        if nargout > 2
            bb = boundingBox(c1);
        else
            bb.x = 1:size(c1, 1);
            bb.y = 1:size(c1, 2);
            bb.z = 1:size(c1, 3);
        end
        pf = prepareOnDisk(output{1}, [numel(bb.x) numel(bb.y) numel(bb.z) nc]);
        if nargout > 1
            c  = prepareOnDisk(output{2}, [numel(bb.x) numel(bb.y) numel(bb.z)]);
        end
        pf(:,:,:,:) = pf1(bb.x,bb.y,bb.z,:);
        clear pf1
        c(:,:,:)    = c1(bb.x,bb.y,bb.z);
        clear c1
        
        
    else % strcmpi(loop, 'component')
        if debug
            if par, fprintf('   - Parallelise on components\n');
            else,   fprintf('   - Serialise on components\n');   end
        end
        [pf1, c1] = spm_diffeo(push, single(f(:,:,:,1)), ipsi, lat);
        pf1(~isfinite(pf1)) = nan;
        c1(~isfinite(c1))   = nan;
        if nargout > 2
            bb = boundingBox(c1);
        else
            bb.x = 1:size(c1, 1);
            bb.y = 1:size(c1, 2);
            bb.z = 1:size(c1, 3);
        end
        pf = prepareOnDisk(output{1}, [numel(bb.x) numel(bb.y) numel(bb.z) nc]);
        if nargout > 1
            c  = prepareOnDisk(output{2}, [numel(bb.x) numel(bb.y) numel(bb.z)]);
        end
        pf(:,:,:,1) = pf1(bb.x,bb.y,bb.z);
        c(:,:,:)    = c1(bb.x,bb.y,bb.z);
        clear c1
        if isa(f, 'file_array')
            for k=2:nc
                pf1 = spm_diffeo(push, single(slicevol(f, k, 4)), ipsi, lat);
                pf1(~isfinite(pf1)) = nan;
                pf(:,:,:,k) = pf1(bb.x,bb.y,bb.z);
            end
        else
            parfor (k=2:nc, par)
                pf1 = spm_diffeo(push, single(f(:,:,:,k)), ipsi, lat);
                pf1(~isfinite(pf1)) = nan;
                pf(:,:,:,k) = pf1(bb.x,bb.y,bb.z);
            end
        end
        clear pf1
    end
    
    % --- Remove input copy if needed
    if same_in_out
        delete(f.fname);
    end
        
    % --- Write on disk
    if ~isempty(output{1})
        pf = saveOnDisk(output{1}, pf, 'name', 'pf');
    end
    if nargout > 1 && ~isempty(output{2})
        c = saveOnDisk(output{2}, c, 'name', 'c');
    end
end
