function pgva_train(input,opt)
% FORMAT pgva_train(input,opt)
% input - Matlab structure or JSON file containing input filenames
% opt   - Matlab structure or JSON file containing option values
%
% Train a PGVA shape model on some data. This is a wrapper around the
% `pgva_model` function that can take JSON files as inputs and that can be
% compiled and used on command line.
%
% Both json should contain structured values (equivalent to a a maltab
% structure). Type `help pgva_model` for details on these structures and
% their fields.

    if nargin > 1
        if ischar(opt)
            try
                opt = spm_jsonread(opt);
            catch
                error('Error reading the option JSON file')
            end
        elseif ~isstruct(opt)
            error('Argument `opt `should be either a Matlab structure or a JSON file')
        end
    else
        opt = struct;
    end
    
    if nargin == 0 || (ischar(input) && ...
            (strcmp(input,'--help') || ...
             strcmp(input,'--h')    || ...
             strcmp(input,'-h')))
        show_instructions;
        return
    elseif ischar(input)
        try
            input = spm_jsonread(input);
        catch
            error('Error reading the input JSON file')
        end
    elseif ~isstruct(opt)
        error('Argument `input` should be either a Matlab structure or a JSON file')
    end
    
    % Convert some inputs
    if isfield(opt, 'z') && isfield(opt.z, 'A0')
        if ischar(opt.z.A0) && exist(opt.z.A0, 'file')
            opt.z.A0 = load(opt.z.A0);
        elseif isnumeric(opt.z.A0) && isvector(opt.z.A0)
            opt.z.A0 = diag(opt.z.A0);
        end
    end
    if isfield(opt, 'q') && isfield(opt.q, 'A0')
        if ischar(opt.q.A0) && exist(opt.q.A0, 'file')
            opt.q.A0 = load(opt.q.A0);
        elseif isnumeric(opt.q.A0) && isvector(opt.q.A0)
            opt.q.A0 = diag(opt.q.A0);
        end
    end
    
    % Run algorithm
    pgva_model(input,opt);

end

% Temporary help
function show_instructions
    descr_str = 'Train a shape model on a set of 2D or 3D images (PGVA)';
    usg_str   = 'Usage: pgva_train input.json opt.json';
    cpr_str   = 'Copyright (C) 2018 Wellcome Centre for Human Neuroimaging';
    help_str  = ['' ...
'INPUT\n' ...
'-----\n' ...
'\n' ...
'The input structure should contain the key "f" associated to a list of \n' ...
'filenames (NIfTI or Analyze format) containing the observed images.\n' ...
'They can be binary, categorical or intensity images. If the list is \n' ...
'two-dimensional, the second dimension (i.e., the most nested one)\n' ...
'should contain different classes (or modalities) of the same subject.\n' ...
'\n' ...
'Optionally, the keys "w", "mu" and "a" can be used to provide an initial\n' ...
'value for, respectively, the principal subspace, template or log-template.\n' ...
'\n' ...
'OPTIONS\n' ...
'-------\n' ...
'\n' ...
'Options take the form of a hierarchical dictionary. We provide\n' ...
'descriptions for the most useful ones using Matlab notations\n' ...
'(key1.key2 should be written {"k1":{"k2":value}} in JSON).\n' ...
'A complete list can be found in the online documentation or README file.\n' ...
'\n' ...
'model.name   - Data type/model:      ''categorical''/''bernoulli''/[''normal'']\n' ...
'model.nc     - (categorical only) Number of classes            [from input]\n' ...
'pg.K         - Number of principal geodesics                   [32]\n' ...
'pg.prm       - Parameters of the geodesic operator             [0.001 0 10 0.1 0.2]\n' ...
'tpl.vs       - Template lattice voxel size                     [auto]\n' ...
'tpl.lat      - Template lattice dimensions                     [auto]\n' ...
'v.l0         - Prior expected anatomical noise precision       [17]\n' ...
'f.M          - Force same voxel-to-world to all images         [from file]\n' ...
'lb.threshold - Convergence criterion (lower bound gain)        [1e-3]\n' ...
'split.par    - Parallelise processing (number of workers): 0/n/[auto]\n' ...
'ui.verbose   - Talk during processing                          [true]\n' ...
'dir.model    - Directory where to store model data             [''.'']\n' ...
'dir.dat      - Directory where to store data arrays            [next to input]\n' ...
    ];
    fprintf([repmat('_',1,80) '\n']);
    fprintf('\n');
    fprintf([' ' descr_str '\n']);
    fprintf('\n');
    fprintf(['     ' usg_str '\n']);
    fprintf('\n');
    fprintf([repmat('-',1,80) '\n']);
    fprintf('\n');
    fprintf(help_str);
    fprintf('\n');
    fprintf([repmat('_',1,80) '\n']);
    fprintf([' ' cpr_str '\n']);
end