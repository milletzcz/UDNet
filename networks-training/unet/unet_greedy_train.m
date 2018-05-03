function net = unet_greedy_train(net,varargin)

run(fullfile(fileparts(mfilename('fullpath')), ...
  '..', '..', 'matlab', 'vl_layers', 'vl_setupnn.m')) ;

%  ---- Network Training Parameters ------
opts.numEpochs = 300; % Maximum number of gradient-descent iterations
opts.batchSize = 50;
opts.batchSize_val = 100;
opts.learningRate = 0.001;
opts.solver = @solver.momentum;
opts.solverOpts = [];%struct('gamma', 0.9, 'decay', 0);
opts.cudnn = true;
opts.backPropDepth = +inf;
opts.net_move = @net_move;
opts.net_eval = @unet_eval;

%Indicate whether to use or not a gpu for the training.
opts.gpus = 1; %[] -> no gpu
opts.plotStatistics = false; % if set to true the graph with the objective is ploted
opts.saveFreq = 10; % Results are saved every opts.saveFreq number of epochs.
opts.conserveMemory = true;


opts.imdbPath = fullfile('..','data', 'imdb.mat');

opts.net_struct={...
  struct('layer_type','unet','first_stage',true), ...
  struct('layer_type','unet','first_stage',true), ...
  struct('layer_type','unet','first_stage',true), ...
  struct('layer_type','unet','first_stage',true), ...
  struct('layer_type','unet','first_stage',true), ...
  struct('layer_type','clip','lb',0,'ub',255),...  
  struct('layer_type','imloss','peakVal',255)};

opts.noise_std = [5,9,13,17,21,25,29];
%  ------ Inverse Problem Parameters ------
% Define the forward model of the inverse problem we are training the
% network to solve.
% y=A(x)+n where A is the forward operator and n is gaussian noise of
% noise_std.

opts.name_id = 'unet';
opts.randn_seed = 124324;

% layer-specific paramaters
%  ----- dprNet -------
opts.patchSize = [5 5];
opts.numFilters = [];
opts.stride = [1,1];
opts.padSize = [];
opts.padType = 'symmetric';
opts.weightSharing = false;
opts.zeroMeanFilters = true;
opts.weightNormalization = true;
opts.rbf_means = -100:4:100;
opts.rbf_precision = [];
opts.rbf_weights = [];
opts.h = [];
opts.ht = [];
opts.s = [];
opts.st = [];
opts.lr = [1,1,1,1,1,1]; % Learning rate for each weight of the stage
opts.first_stage = true;
opts.data_mu = [];
opts.step = 0.1;
opts.origin = -104;
opts.shrink_type = 'identity';
opts.alpha = 0;
opts.clb = -100;
opts.cub = 100;

% --- Imloss layer -----
opts.peakVal = 255;
opts.loss_type = 'psnr';

% --- CLIP layer -----
opts.lb = 0;
opts.ub = 255;

opts.cid = 'single';
%opts.cid='double';

[opts,varargin] = vl_argparse(opts, varargin);

if isempty(opts.solverOpts)
  opts.solverOpts = opts.solver();
end

if isempty(opts.data_mu)
  opts.data_mu=cast(opts.origin:opts.step:-opts.origin,opts.cid);
  opts.data_mu=bsxfun(@minus,opts.data_mu,cast(opts.rbf_means(:),opts.cid));
end

opts.netParams = struct('data_mu',opts.data_mu,'step',opts.step,'origin',opts.origin);

% How many unet stages the network consists of.
if isempty(net)  
  numStages = 0;
  for k=1:numel(opts.net_struct)
    if isequal(opts.net_struct{k}.layer_type,'unet')
      numStages = numStages+1;
    end
  end
else
  numStages = 0;
  for k=1:numel(net.layers)
    if isequal(net.layers{k}.type,'unet')
      numStages = numStages+1;
    end
  end
end

str_solver = char(opts.solver);
str_solver = str_solver(strfind(str_solver,'.')+1:end);

if numel(opts.noise_std) == 1
  str_std = sprintf('%0.f',opts.noise_std(1));
else
  str_std = [ '[' num2str(opts.noise_std) ']' ];
  str_std = regexprep(str_std,'\s*',',');
end

if opts.weightSharing
  str_ws = '-WS';
else
  str_ws = '';
end

opts.expDir = fullfile('Results', ...
  sprintf('%s-stages:%.0f-psize:%.0fx%.0f@%d%s-std:%s-solver:%s-greedyTrain',...
  opts.name_id,numStages,opts.patchSize(1),opts.patchSize(2),...
  opts.numFilters,str_ws,str_std,str_solver));

if ~exist(opts.expDir, 'dir')
  mkdir(opts.expDir);
  copyfile([mfilename '.m'], [opts.expDir filesep]);
  save([opts.expDir filesep 'arg_In'],'opts');
end

opts = vl_argparse(opts, varargin);

% -------------------------------------------------------------------------
%                Prepare Data and Model
% -------------------------------------------------------------------------
imdb = load(opts.imdbPath);
if ~isequal(opts.cid,'single')
  imdb.images.data = cast(imdb.images.data,opts.cid);
end

%imdb.images.data = imdb.images.data(:,:,:,313:321);% 8:10
%imdb.images.set = imdb.images.set(313:321);

noise_levels = numel(opts.noise_std);
imdb.images.set = imdb.images.set(:);
imdb.images.set = repmat(imdb.images.set,noise_levels,1); % Every image is 
% corrupted by K different noise levels and all the K instances are used 
% either for training or for validation.


% Create the noise added to the data according to the chosen standard
% deviation of the noise.

% Initialize the seed for the random generator
s = RandStream('mt19937ar','Seed',opts.randn_seed);
RandStream.setGlobalStream(s);

% The degraded input that we feed to the network and we want to
% reconstruct.
imdb.images.obs = [];
for k=1:noise_levels
  imdb.images.obs = cat(4,imdb.images.obs, imdb.images.data + ...
  opts.noise_std(k)*randn(size(imdb.images.data),opts.cid));
end
imdb.images.noise_std = opts.noise_std;
imdb.images.stage_input = [];

opts.inputSize = size(imdb.images.data(:,:,:,1));
% Initialize network parameters
% Initialize network parameters
if isempty(net)
  net = net_init_from_struct(opts);
else
  net.meta.trainOpts.inputSize = opts.inputSize;
  net.meta.trainOpts.noise_std = opts.noise_std;
  net.meta.trainOpts.randSeed = opts.randn_seed;
  net.meta.trainOpts.numEpochs = opts.numEpochs;
  net.meta.trainOpts.learningRate = opts.learningRate;
  net.meta.trainOpts.optimizer = char(opts.solver);
  net.meta.netParams = opts.netParams;
end

% -------------------------------------------------------------------------
%                     Train Network Stage by Stage
% -------------------------------------------------------------------------

train_image_set = find(imdb.images.set == 1);
val_image_set = find(imdb.images.set == 2);

useGPU = ~isempty(opts.gpus);

N = numel(imdb.images.set); % How many images we are using for testing and
% validation.
N_gt = size(imdb.images.data,4); % How many unique images are used.

for stage = 1:numStages
  net_ = net;
  net_.layers = [net.layers(stage), net.layers(numStages+1:end)];
    
  expDir_stage = fullfile(opts.expDir,['stage-' num2str(stage)]);
  if ~exist(expDir_stage,'dir')
    mkdir(expDir_stage);
  end
  
  start_time = tic;
  net_ = deep_net_train(net_, imdb, @getBatch, ...
    'expDir', expDir_stage, ...
    'solver', opts.solver, ...
    'solverOpts', opts.solverOpts, ...
    'batchSize', opts.batchSize, ...
    'gpus', opts.gpus,...
    'train', train_image_set, ...
    'val', val_image_set, ...    
    'numEpochs', opts.numEpochs, ...
    'learningRate', opts.learningRate, ...
    'conserveMemory', opts.conserveMemory, ...
    'backPropDepth', opts.backPropDepth, ...
    'cudnn', opts.cudnn, ...
    'saveFreq', opts.saveFreq, ...
    'plotStatistics', opts.plotStatistics, ...    
    'netParams', opts.netParams, ...
    'net_move', opts.net_move, ...
    'net_eval', opts.net_eval);
  
  net_.layers(2:end)=[]; % Remove the loss layer  
  net.layers(stage) = net_.layers(1);
  
  train_time = toc(start_time);
  fprintf('\n-------------------------------------------------------\n')
  fprintf('\n\n The training for stage %d was completed in %.2f secs.\n\n',stage,train_time);
  fprintf('-------------------------------------------------------\n')
    
  if stage == numStages
    for k=2:numStages
      net.layers{k}.first_stage = false;
    end
    save(fullfile(opts.expDir,'net-final.mat'), 'net');
  else
    net_s = net;
    net.layers = [net.layers(1:stage), net.layers(numStages+1:end)];
    for k=2:stage
      net.layers{k}.first_stage = false;
    end
    save(fullfile(expDir_stage,'net-final.mat'), 'net');
    net = net_s;
    clear net_s;
  end
  
  
  if stage < numStages
    
    if useGPU
      clearMex();
      gpuDevice(opts.gpus(1));
      net_ = opts.net_move(net_,'gpu');
    end
    
    if stage==1
      imdb.images.stage_input = zeros(size(imdb.images.obs),opts.cid);
    end
    
    
    for t = 1:opts.batchSize_val:N
      batchStart = t;
      batchEnd = min(t+opts.batchSize_val-1,N);
      
      noise_std = opts.noise_std(ceil((batchStart:batchEnd)/N_gt));
      
      obs = imdb.images.obs(:,:,:,batchStart:batchEnd);
      if stage ~= 1
        input = imdb.images.stage_input(:,:,:,batchStart:batchEnd);
      end
      
      if useGPU
        obs = gpuArray(obs);
        if stage ~= 1
          input = gpuArray(input);
        end
      end      
      
      if stage == 1                
        res=opts.net_eval(net_,obs,[],[],'conserveMemory',true, ...
          'cudnn', opts.cudnn, 'netParams',struct('data_mu', ...
          opts.data_mu,'stdn',noise_std,'Obs',[]));
      else
        res=opts.net_eval(net_,input,[],[],'conserveMemory',true, ...
          'cudnn', opts.cudnn, 'netParams', struct('data_mu', ...
          opts.data_mu,'stdn',noise_std,'Obs', obs));
      end
      
      if useGPU
        imdb.images.stage_input(:,:,:,batchStart:batchEnd) = gather(parseInput(res(end).x));
      else
        imdb.images.stage_input(:,:,:,batchStart:batchEnd) = parseInput(res(end).x);
      end      
    end
    clear res input obs;
  end
  
end


function [im, im_gt, aux] = getBatch(imdb,batch)

N_gt = size(imdb.images.data,4);% Number of unique ground-truth images used 
% for training / testing.
im_gt = imdb.images.data(:,:,:,mod(batch-1,N_gt)+1);

if isempty(imdb.images.stage_input)
  im = imdb.images.obs(:,:,:,batch); % This is for the 1st stage of the 
  % network where the stage input is the same with the network input.
else
  im = imdb.images.stage_input(:,:,:,batch); % The input of the current stage
% of the network.
end

% imdb.images.obs : The input of the first stage of the network

% Instead of using a vector noise_std of size N_gt*K (K : number of
% the different noise levels and N_gt the number of unique ground-truth 
% images) we use only a vector of size K. Then the first 1:N_gt images in 
% the data set are distorted by noise with standard deviation equal to 
% noise_std(1), the next N_gt+1:2*N_gt by noise with standard deviation 
% equal to im_noise_std(2), etc.
aux = struct('Obs',imdb.images.obs(:,:,:,batch),'stdn',...
  imdb.images.noise_std(ceil(batch/N_gt)));


function x = parseInput(x)
if iscell(x)
  x = x{end};  
end


% -------------------------------------------------------------------------
%                       Initialize Network
% -------------------------------------------------------------------------

function net = net_init_from_struct(opts)

net_add_layer = @unet_add_layer;
net.layers = {};
num_layers = numel(opts.net_struct);

for l = 1:num_layers
  
  switch opts.net_struct{l}.layer_type
    
    case 'unet'
      if ~isfield(opts.net_struct{l},'alpha')
        opts.net_struct{l}.alpha = opts.alpha;
      end       
      if ~isfield(opts.net_struct{l},'patchSize')
        opts.net_struct{l}.patchSize = opts.patchSize;
      end
      if ~isfield(opts.net_struct{l},'stride')
        opts.net_struct{l}.stride = opts.stride;
      end
      if ~isfield(opts.net_struct{l},'padSize')
        opts.net_struct{l}.padSize = opts.padSize;
      end
      if ~isfield(opts.net_struct{l},'padType')
        opts.net_struct{l}.padType = opts.padType;
      end      
      if ~isfield(opts.net_struct{l},'h')
        opts.net_struct{l}.h = opts.h;
      end
      if ~isfield(opts.net_struct{l},'ht')
        opts.net_struct{l}.ht = opts.ht;
      end      
      if ~isfield(opts.net_struct{l},'s')
        opts.net_struct{l}.s = opts.s;
      end
      if ~isfield(opts.net_struct{l},'st')
        opts.net_struct{l}.st = opts.st;
      end            
      if ~isfield(opts.net_struct{l},'weightSharing')
        opts.net_struct{l}.weightSharing = opts.weightSharing;
      end
      if ~isfield(opts.net_struct{l},'weightNormalization')
        opts.net_struct{l}.weightNormalization = opts.weightNormalization;
      end      
      if ~isfield(opts.net_struct{l},'zeroMeanFilters')
        opts.net_struct{l}.zeroMeanFilters = opts.zeroMeanFilters;
      end            
      if ~isfield(opts.net_struct{l},'numFilters')
        opts.net_struct{l}.numFilters = opts.numFilters;
      end
      if ~isfield(opts.net_struct{l},'rbf_means')
        opts.net_struct{l}.rbf_means = opts.rbf_means;
      end
      if ~isfield(opts.net_struct{l},'rbf_precision')
        opts.net_struct{l}.rbf_precision = opts.rbf_precision;
      end
      if ~isfield(opts.net_struct{l},'rbf_weights')
        opts.net_struct{l}.rbf_weights = opts.rbf_weights;
      end
      if ~isfield(opts.net_struct{l},'learningRate')
        opts.net_struct{l}.learningRate = opts.lr;
      end
      if ~isfield(opts.net_struct{l},'first_stage')
        opts.net_struct{l}.first_stage = opts.first_stage;
      end
      if ~isfield(opts.net_struct{l},'shrink_type')
        opts.net_struct{l}.shrink_type = opts.shrink_type;
      end
      if ~isfield(opts.net_struct{l},'clb')
        opts.net_struct{l}.clb = opts.clb;
      end
      if ~isfield(opts.net_struct{l},'cub')
        opts.net_struct{l}.cub = opts.cub;
      end      
      
      net = net_add_layer(net, ...
        'alpha', opts.net_struct{l}.alpha, ...
        'layer_id', l, ...
        'inputSize', opts.inputSize, ...
        'layer_type', opts.net_struct{l}.layer_type, ...
        'cid', opts.cid, ...
        'patchSize',opts.net_struct{l}.patchSize, ...
        'numFilters', opts.net_struct{l}.numFilters, ...        
        'stride', opts.net_struct{l}.stride, ...
        'padSize', opts.net_struct{l}.padSize, ...
        'padType', opts.net_struct{l}.padType, ...
        'shrink_type', opts.net_struct{l}.shrink_type, ...
        'h', opts.net_struct{l}.h, ...
        's', opts.net_struct{l}.s, ...
        'ht', opts.net_struct{l}.ht, ...
        'st', opts.net_struct{l}.st, ...
        'zeroMeanFilters', opts.net_struct{l}.zeroMeanFilters, ...
        'weightNormalization', opts.net_struct{l}.weightNormalization, ...
        'weightSharing', opts.net_struct{l}.weightSharing, ...        
        'rbf_means', opts.net_struct{l}.rbf_means, ...
        'rbf_precision', opts.net_struct{l}.rbf_precision, ...
        'rbf_weights', opts.net_struct{l}.rbf_weights, ...
        'learningRate', opts.net_struct{l}.learningRate, ...
        'first_stage', opts.net_struct{l}.first_stage, ...
        'clb', opts.net_struct{l}.clb, ... 
        'cub', opts.net_struct{l}.cub);

    case 'clip'
      if ~isfield(opts.net_struct{l},'lb')
        opts.net_struct{l}.lb = opts.lb;
      end
      if ~isfield(opts.net_struct{l},'ub')
        opts.net_struct{l}.ub = opts.ub;
      end
      net = net_add_layer(net,'layer_id',l, ...
        'layer_type', opts.net_struct{l}.layer_type, ...
        'lb',opts.net_struct{l}.lb, ...
        'ub',opts.net_struct{l}.ub);      
      
    case 'imloss'
      if ~isfield(opts.net_struct{l},'peakVal')
        opts.net_struct{l}.peakVal = opts.peakVal;
      end
      if ~isfield(opts.net_struct{l},'loss_type')
        opts.net_struct{l}.loss_type = opts.loss_type;
      end
      net = net_add_layer(net,'layer_id',l, ...
        'layer_type', opts.net_struct{l}.layer_type, ...
        'peakVal',opts.net_struct{l}.peakVal, ...
        'loss_type',opts.net_struct{l}.loss_type);
  end
end

% Meta parameters
net.meta.trainOpts.inputSize = opts.inputSize;
net.meta.trainOpts.noise_std = opts.noise_std;
net.meta.trainOpts.randSeed = opts.randn_seed;
net.meta.trainOpts.numEpochs = opts.numEpochs;
net.meta.trainOpts.learningRate = opts.learningRate;
net.meta.trainOpts.optimizer = char(opts.solver);
net.meta.netParams = opts.netParams;

% -------------------------------------------------------------------------
function clearMex()
% -------------------------------------------------------------------------
%clear vl_tmove vl_imreadjpeg ;
disp('Clearing mex files');
clear mex;
clear vl_tmove vl_imreadjpeg;
