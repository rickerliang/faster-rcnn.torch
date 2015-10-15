require 'torch'
require 'pl'
require 'optim'
require 'image'
require 'nngraph'
require 'cunn'
require 'nms'
require 'gnuplot'

require 'utilities'
require 'Anchors'
require 'BatchIterator'
require 'objective'
--require 'Detector'


-- command line options
cmd = torch.CmdLine()
cmd:addTime()

cmd:text()
cmd:text('Training a convnet for region proposals')
cmd:text()

cmd:text('=== Training ===')
cmd:option('-cfg', 'config/imagenet.lua', 'configuration file')
cmd:option('-model', 'models/vgg_small.lua', 'model factory file')
cmd:option('-name', 'imgnet', 'experiment name, snapshot prefix') 
cmd:option('-train', 'ILSVRC2015_DET.t7', 'training data file name')
cmd:option('-restore', '', 'network snapshot file name to load')
cmd:option('-snapshot', 1000, 'snapshot interval')
cmd:option('-plot', 100, 'plot training progress interval')
cmd:option('-lr', 1E-4, 'learn rate')
cmd:option('-rms_decay', 0.9, 'RMSprop moving average dissolving factor')
cmd:option('-opti', 'rmsprop', 'Optimizer')

cmd:text('=== Misc ===')
cmd:option('-threads', 8, 'number of threads')
cmd:option('-gpuid', 0, 'device ID (CUDA), (use -1 for CPU)')
cmd:option('-seed', 0, 'random seed (0 = no fixed seed)')

print('Command line args:')
local opt = cmd:parse(arg or {})
print(opt)

print('Options:')
local cfg = dofile(opt.cfg)
print(cfg)

-- system configuration
torch.setdefaulttensortype('torch.FloatTensor')
cutorch.setDevice(opt.gpuid + 1)  -- nvidia tools start counting at 0
torch.setnumthreads(opt.threads)
if opt.seed ~= 0 then
  torch.manualSeed(opt.seed)
  cutorch.manualSeed(opt.seed)
end

function plot_training_progress(prefix, stats)
  local fn = prefix .. '_progress.png'
  gnuplot.pngfigure(fn)
  gnuplot.title('Traning progress over time')
  
  local xs = torch.range(1, #stats.pcls)
  
  gnuplot.plot(
    { 'pcls', xs, torch.Tensor(stats.pcls), '-' },
    { 'preg', xs, torch.Tensor(stats.preg), '-' },
    { 'dcls', xs, torch.Tensor(stats.dcls), '-' },
    { 'dreg', xs, torch.Tensor(stats.dreg), '-' }
  )
 
  gnuplot.axis({ 0, #stats.pcls, 0, 10 })
  gnuplot.xlabel('iteration')
  gnuplot.ylabel('loss')
  
  gnuplot.plotflush()
end


function graph_training(cfg, model_path, snapshot_prefix, training_data_filename, network_filename)
  print('Reading training data file \'' .. training_data_filename .. '\'.')
  local training_data = load_obj(training_data_filename)
  local file_names = keys(training_data.ground_truth)
  print(string.format("Training data loaded. Dataset: '%s'; Total files: %d; classes: %d; Background: %d)", 
      training_data.dataset_name, 
      #file_names,
      #training_data.class_names,
      #training_data.background_files))
  
  training_data.cfg = cfg  -- add cfg
  
  local training_stats = { pcls={}, preg={}, dcls={}, dreg={} }
  
  local stored
  if network_filename and #network_filename > 0 then
    stored = load_obj(network_filename)
    training_stats = stored.stats
  end
  
  -- create model
  local model_factory = dofile(model_path)
  local model = model_factory(cfg)
  
  model.cnet:cuda()
  model.pnet:cuda()
  
  -- combine parameters from pnet and cnet into flat tensors
  local weights, gradient = combine_and_flatten_parameters(model.pnet, model.cnet)
  if stored then
    weights:copy(stored.weights)
  end
  
  local batchIterator = BatchIterator.new(model, training_data)
  local eval_objective_grad = create_objective(model, weights, gradient, batchIterator, training_stats)
  
  local rmsprop_state = { learningRate = opt.lr, alpha = opt.rms_decay }
  --local nag_state = { learningRate = opt.lr, weightDecay = 0, momentum = opt.rms_decay }
  --local sgd_state = { learningRate = 0.000025, weightDecay = 1e-7, momentum = 0.9 }
  
  for i=1,50000 do
    if i % 5000 == 0 then
      opt.lr = opt.lr / 2
      rmsprop_state.lr = opt.lr
    end
  
    local timer = torch.Timer()
    local _, loss = optim.rmsprop(eval_objective_grad, weights, rmsprop_state)
    --local _, loss = optim.nag(optimization_target, weights, nag_state)
    --local _, loss = optim.sgd(optimization_target, weights, sgd_state)
    
    local time = timer:time().real

    print(string.format('%d: loss: %f', i, loss[1]))
    
    if i%opt.plot == 0 then
      plot_training_progress(snapshot_prefix, training_stats)
    end
    
    if i%opt.snapshot == 0 then
      -- save snapshot
      save_model(string.format('%s_%06d.t7', snapshot_prefix, i), weights, opt, training_stats)
    end
    
  end
  
  -- compute positive anchors, add anchors to ground-truth file
end


graph_training(cfg, opt.model, opt.name, opt.train, opt.restore)


-- TODO: remove
local base_path = '/home/koepf/datasets/brickset_all/'
local testset_path = '/home/koepf/datasets/realbricks/'

function load_image_auto_size(fn, target_smaller_side, max_pixel_size, color_space)
  local img = image.load(path.join(base_path, fn), 3, 'float')
  local dim = img:size()
  
  local w, h
  if dim[2] < dim[3] then
    -- height is smaller than width, set h to target_size
    w = math.min(dim[3] * target_smaller_side/dim[2], max_pixel_size)
    h = dim[2] * w/dim[3]
  else
    -- width is smaller than height, set w to target_size
    h = math.min(dim[2] * target_smaller_side/dim[1], max_pixel_size)
    w = dim[3] * h/dim[2]
  end
  
  img = image.scale(img, w, h)
  
  if color_space == 'yuv' then
    img = image.rgb2yuv(img)
  elseif color_space == 'lab' then
    img = image.rgb2lab(img)
  elseif color_space == 'hsv' then
    img = image.rgb2hsv(img)
  end

  return img, dim
end

function evaluation_demo()
  -- get configuration & model
  
  -- create detector
  
  -- run detector on images
  
  -- draw bounding boxes and save image
end

--graph_evaluate(duplo_cfg, 'duplo.t7', 'duplo_036000.t7', true, 17)
