function pgva_compile(compile_dir)
% FORMAT pgva_compile(compile_dir)
%
% Script for compiling the MATLAB code for the PGVA shape model
%__________________________________________________________________________
% Copyright (C) 2017 Wellcome Trust Centre for Neuroimaging

% John Ashburner
% $Id$

if nargin < 1
    compile_dir = fullfile(tempdir,'compiled');
end

if ~exist('spm','file')
    error('SPM not on search path.');
end

if ~strcmp(spm('ver'),'SPM12')
    error('Wrong SPM version installed (should be SPM12).');
end

spm_file  = which('spm');
[pth,~,~] = fileparts(spm_file);

addpath(pth);
addpath(fullfile(pth,'toolbox','Shoot'));

setpath('pgva');

[ok,message] = mkdir(compile_dir);
if ok
    fprintf('Compiled results should be in "%s"\n', compile_dir)
    mcc('-m','pgva_train',   '-v','-d',compile_dir);
    mcc('-m','pgva_fit','-v','-d',compile_dir); 
    disp('Done.');
else
    error(message);
end